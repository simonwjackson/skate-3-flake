// Host-only harness. packed-descriptors-extracted.inc contains the actual SDK
// function and constants, not a second implementation of the remapper.
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include "packed-descriptors-extracted.inc"

using Words = std::vector<uint32_t>;
const Words kSentinel = {0xdeadbeefu, 0x12345678u};

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

void unchanged(const std::string& label, Words words, size_t bytes) {
  const Words before = words;
  Words out = kSentinel;
  require(!RemapTableDescriptorSets(words.data(), bytes, &out), label + ": expected false");
  require(words == before, label + ": input modified");
  require(out == kSentinel, label + ": false return modified output");
}

void edge_tests() {
  const Words header = {0x07230203u, 0x00010300u, 0, 100, 0};
  Words out = kSentinel;
  require(!RemapTableDescriptorSets(nullptr, 20, &out), "null pointer");
  require(out == kSentinel, "null pointer modified output");
  unchanged("empty", {}, 0);
  unchanged("short header", header, 16);
  unchanged("unaligned size", header, 19);
  auto words = header;
  words.push_back(0);
  unchanged("unaligned size beyond header", words, 21);
  words = header;
  words[0] = 0;
  unchanged("wrong magic", words, words.size() * 4);
  unchanged("header only", header, header.size() * 4);
  words = header;
  words.insert(words.end(), {0x00040047u, 1, 34, 0, 0x00040047u, 1, 33, 7});
  unchanged("set zero only", words, words.size() * 4);
  words = header;
  words.push_back(71);  // Zero instruction length.
  unchanged("zero length", words, words.size() * 4);
  words.back() = 0x00040047u;
  unchanged("truncated instruction", words, words.size() * 4);
  words = header;
  words.insert(words.end(), {0x00030047u, 1, 34});
  // This helper is not a full SPIR-V validator: a short decoration is ignored.
  unchanged("short decoration ignored", words, words.size() * 4);
  words = header;
  words.insert(words.end(), {0x00040047u, 1, 34, 4, 0});
  unchanged("malformed after remappable set", words, words.size() * 4);
  words.back() = 0x00040047u;
  unchanged("truncated after remappable set", words, words.size() * 4);
  words = header;
  words.insert(words.end(), {0x00040047u, 1, 34, 1, 0x00040047u, 1, 33, 7});
  const Words before = words;
  // Set 1 already has its final coordinates, but this implementation returns
  // true and copies it. Do not mistake "true" for "some words changed".
  require(RemapTableDescriptorSets(words.data(), words.size() * 4, &out), "set one return");
  require(out == before && words == before, "set one should be byte-identical");
  std::cout << "PASS: empty, malformed, set-zero and set-one behavior\n";
}

int main(int argc, char** argv) {
  try {
    if (argc == 1) {
      edge_tests();
      return 0;
    }
    require(argc == 3, "expected input and output paths");
    std::ifstream input(argv[1], std::ios::binary | std::ios::ate);
    require(bool(input), "open input");
    const auto bytes = input.tellg();
    require(bytes >= 20 && bytes % 4 == 0, "input size");
    Words words(static_cast<size_t>(bytes) / 4);
    input.seekg(0);
    input.read(reinterpret_cast<char*>(words.data()), bytes);
    require(bool(input), "read input");
    const Words before = words;
    Words out = kSentinel;
    const bool remapped = RemapTableDescriptorSets(words.data(), size_t(bytes), &out);
    require(words == before, "original shader modified");
    require(remapped || out == kSentinel, "false return modified output");
    const Words& result = remapped ? out : words;
    std::ofstream output(argv[2], std::ios::binary);
    output.write(reinterpret_cast<const char*>(result.data()), result.size() * 4);
    output.close();
    require(bool(output), "write output");
    std::cout << (remapped ? "true" : "false") << '\n';
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
