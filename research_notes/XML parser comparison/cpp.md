# C++ XML parsers: pugixml and RapidXML

## Speed and benchmark credibility

### Takeaway
Both are performance-oriented DOM parsers. Public upstream benchmarks are useful historical evidence, not a current ranking against quick-xml.

### Cited Findings
- pugixml's published comparison uses Visual Studio 2015, an Intel Core i7 2.67 GHz, nine 1–20 MB files, default settings, and the minimum repeated runtime. Parsing begins from memory; DOM builds trees, SAX uses dummy callbacks, and pull consumes events. That is unequal application work and omits ZIP extraction, spreadsheet conversion and disk I/O. — [Benchmark methodology](https://pugixml.org/benchmark.html)
- RapidXML's headline speed comparison uses a 50 KB document, fastest modes, minimum CPU cycles, circa-2007 processors/compiler versions and **pugixml 0.3**. Its claim of being 5–30% faster cannot establish superiority over pugixml 1.16 or present quick-xml. — [Original manual §4.1](https://rapidxml.sourceforge.net/manual.html#section_performance)

### Inferences
- A spreadsheet comparison needs identical text unescaping, end-tag checks, cell extraction and numeric conversions. Benchmarking only event scanning versus DOM construction cannot determine total XLSX import time.
- Pugi/Rapid can plausibly compete strongly for in-memory XML; streaming avoids allocating a DOM that our application would immediately discard. This is an architectural expectation, not a measured win.

### Gaps
- No current, controlled quick-xml versus pugixml 1.16 versus RapidXML versus Expat benchmark was established in this research. No app-specific throughput claim is justified.

## Robustness and standards support

### Takeaway
Robustness has separate meanings: crash resistance, strict malformed-input detection and supported XML semantics. Pugixml and RapidXML deliberately omit some checks/features for speed.

### Cited Findings
- Pugixml documents permissive well-formedness checks: duplicate attributes, invalid names/references/UTF sequences and multiple root elements may pass. DOCTYPE-defined entities are not expanded. Its XPath matches QNames rather than namespace-expanded names. Compact DOM mode reduces memory at some processing cost. — [Manual §§3.6.4, 4.7, 8.6](https://pugixml.org/docs/manual.html)
- Original RapidXML does not process DTDs and has limited entity substitution. Its default does **not validate matching closing tags**; `parse_validate_closing_tags` enables this, and `parse_full` includes it. — [Manual](https://rapidxml.sourceforge.net/manual.html)
- In Boost's bundled RapidXML implementation, `parse_fastest` disables entity translation and data-node creation; `parse_full` adds end-tag checks and additional node kinds. This is evidence from the Boost copy, not a claim that every fork behaves identically. — [Boost source](https://raw.githubusercontent.com/boostorg/property_tree/develop/include/boost/property_tree/detail/rapidxml.hpp)
- Pugixml 1.16 was released June 16, 2026; its release includes fixes for deeply nested subtree removal and large-input integer overflow on 32-bit wchar builds. — [Release](https://github.com/zeux/pugixml/releases/tag/v1.16)
- Original RapidXML's official site still advertises 1.13 and carries 2006–2009 copyright. That is the original project; independent forks and Boost's copy require separate assessment. — [Original upstream](https://rapidxml.sourceforge.net/)

### Inferences
- “Non-validating” should not be used loosely: not validating a document against a schema/DTD is distinct from accepting mismatched tags or malformed Unicode.
- Missing DTD expansion avoids that expansion mechanism, but does not prove a library is safe against every hostile input. Compare documented limits, current versions and configurations rather than CVE counts alone.
- I would not choose original RapidXML for externally supplied workbooks merely from its speed headline; permissive defaults and the age of its published upstream materials require deliberate evaluation.

### Gaps
- No exhaustive security audit or all-forks comparison performed. No claim that age proves exploitable vulnerabilities.

## Size, memory, capabilities and Zig integration

### Takeaway
Both libraries are C++, not C. They buy convenient tree access at the cost of holding input and DOM data; their source packaging is not an executable-size benchmark.

### Cited Findings
- Pugixml provides mutable DOM, serialization and XPath 1.0; source consists of one `.cpp` and two headers. It accepts immutable and in-place buffers, with caller-owned in-place input required to outlive the document. UTF-8/16/32 conversions are available. — [Quick start](https://pugixml.org/docs/quickstart.html)
- Pugixml can disable XPath, STL and exceptions, enable compact mode and tune allocation page sizes. — [v1.16 config](https://raw.githubusercontent.com/zeux/pugixml/v1.16/src/pugiconfig.hpp)
- RapidXML is a single-header in-situ DOM parser with optional printer/helper headers. Names and values borrow input storage; normal parsing modifies the buffer. Input must outlive the tree. It has no general encoding conversion. — [Original manual](https://rapidxml.sourceforge.net/manual.html)
- Boost PropertyTree bundles RapidXML 1.13 and adds its own property-tree conversion. Mixed text/element ordering can be lost with default conversion, and its encoding handling has additional caveats. It is not simply another name for the standalone DOM API. — [Boost documentation](https://www.boost.org/doc/libs/latest/doc/html/property_tree/parsers.html)

### Inferences
- Neither is a direct Zig `@cImport` replacement; a C-compatible shim and C++ compilation would be needed. Expat's existing C callback API is simpler for the current integration.
- Pugixml makes sense when XPath, revisiting arbitrary nodes or editing/serializing XML is valuable. RapidXML makes sense for tightly controlled in-place DOM use with carefully selected flags and input lifetime handling. Streaming Expat/quick-xml is a better architectural fit for extracting worksheet cells in one pass.
- Distinguish source footprint, final stripped executable increment, peak heap/RSS and retained workbook cells. A one-header parser need not yield the smallest binary or lowest runtime memory.

### Gaps
- No same-target binary-size measurement was performed. Do not rank these by downloaded archive size or quoted source line counts. No application code changed.
