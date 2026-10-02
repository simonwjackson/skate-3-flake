// Exercise the real GTKWindow implementation with GTK's real event loop.
// No renderer is needed: expose the platform hook that Window::RequestPaint
// calls once a presenter surface exists. Producers stop before close, just as
// the presenter disconnects from the surface before the native window closes.
#include <dlfcn.h>
#include <gtk/gtk.h>
#include <rex/ui/window_gtk.h>
#include <rex/ui/windowed_app_context_gtk.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>
#include <vector>

namespace {
const auto ui_thread = std::this_thread::get_id();
std::atomic<unsigned> redraws{0};

void Require(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}

class PaintWindow : public rex::ui::GTKWindow {
 public:
  explicit PaintWindow(rex::ui::WindowedAppContext& context)
      : GTKWindow(context, "GTK repaint regression", 320, 240) {}
  using GTKWindow::RequestPaintImpl;
};

void Drain() {
  // Wait for our queued work, not for the whole GTK loop to become empty:
  // X11 can deliver another event between two g_main_context_pending calls.
  bool dispatched = false;
  const auto source = g_idle_add_full(
      G_PRIORITY_LOW,
      [](gpointer data) -> gboolean {
        *static_cast<bool*>(data) = true;
        return G_SOURCE_REMOVE;
      },
      &dispatched, nullptr);
  const auto deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (!dispatched && g_get_monotonic_time() < deadline) {
    g_main_context_iteration(nullptr, false);
  }
  if (!dispatched) {
    g_source_remove(source);
  }
  Require(dispatched, "queued GTK work was not dispatched");
}

void Burst(PaintWindow& window) {
  std::vector<std::thread> producers;
  for (unsigned i = 0; i < 4; ++i) {
    producers.emplace_back([&window] {
      for (unsigned j = 0; j < 10000; ++j) {
        window.RequestPaintImpl();
      }
    });
  }
  for (auto& producer : producers) {
    producer.join();
  }
}
}  // namespace

// Interpose the real GTK entry point, not a replacement widget. Verify thread
// ownership before forwarding every call to GTK. This goes red on the original
// GPU-thread call without waiting for GTK's list corruption to cause SIGSEGV.
extern "C" void gtk_widget_queue_draw(GtkWidget* widget) {
  Require(std::this_thread::get_id() == ui_thread, "GTK redraw outside UI thread");
  static auto real =
      reinterpret_cast<void (*)(GtkWidget*)>(dlsym(RTLD_NEXT, "gtk_widget_queue_draw"));
  Require(real != nullptr, "cannot find real GTK redraw");
  ++redraws;
  real(widget);
}

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  rex::ui::GTKWindowedAppContext context;
  for (unsigned cycle = 0; cycle < 20; ++cycle) {
    auto window = std::make_unique<PaintWindow>(context);
    Require(window->Open(), "open window");
    Drain();
    auto before = redraws.load();
    Burst(*window);
    Require(redraws == before, "worker burst called GTK before UI dispatch");
    Drain();
    Require(redraws == before + 1, "worker requests were not coalesced into one redraw");

    // Close with a request pending, then pump and reopen the same window.
    Burst(*window);
    window->RequestClose();
    Drain();
    Require(window->window() == nullptr, "native window did not close");
    Require(window->Open(), "reopen window");
    Drain();
    before = redraws.load();
    Burst(*window);
    Drain();
    Require(redraws == before + 1, "redraw after reopen");

    // Delete the C++ owner before the pending idle callback runs.
    Burst(*window);
    before = redraws.load();
    window.reset();
    Drain();
    Require(redraws == before, "redraw after owner destruction");
  }
  std::puts("PASS: UI-thread redraw, coalescing, close/reopen and pending destruction (20 cycles)");
}
