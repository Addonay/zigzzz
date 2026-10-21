# quick-xml and Calamine

## Architecture, capabilities, footprint

### Takeaway
quick-xml is a Rust pull/event reader and writer, designed for selective streaming with reusable buffers and borrowed data. Its memory model is a closer match to Expat than to an entire mutable DOM; that does not establish an actual speed or binary-size winner.

### Cited Findings
- Upstream describes the reader as nearly zero-copy using `Cow`, with reusable buffers. For in-memory slices the reader can borrow the original input; buffered event data borrows a supplied buffer, and retaining an event using `into_owned()` allocates. [Tagged README](https://raw.githubusercontent.com/tafia/quick-xml/v0.42.0/README.md); [Event lifetimes](https://docs.rs/quick-xml/0.42.0/quick_xml/events/enum.Event.html#lifetime).
- API includes text, CDATA, comments, declaration, processing instruction, DOCTYPE and general-reference events. Emitting a DOCTYPE event is not equivalent to validating DTD content. [Event](https://docs.rs/quick-xml/0.42.0/quick_xml/events/enum.Event.html).
- Base `Reader` does not resolve namespaces; `NsReader` does. Optional features add Tokio async I/O, encoding support and Serde serialization/deserialization. [Reader](https://docs.rs/quick-xml/0.42.0/quick_xml/reader/struct.Reader.html); [crate docs](https://docs.rs/quick-xml/0.42.0/quick_xml/).
- Custom-entity resolution is supplied through a callback; `unescape_with` does not recursively expand nested entities, which callers must implement themselves if required. This is not a general DTD-processing/validation engine. [unescape_with](https://docs.rs/quick-xml/0.42.0/quick_xml/escape/fn.unescape_with.html).
- Cargo default features are empty. The sole mandatory normal dependency shown is memchr; encoding_rs, Tokio, Serde and others are optional. Package excludes tests/examples/benchmarks. These are dependency/source footprint facts, not linked executable sizes. [Cargo.toml](https://raw.githubusercontent.com/tafia/quick-xml/master/Cargo.toml).

### Inferences
- Streaming can avoid retaining a document tree, but retained spreadsheet cells/shared strings and the largest buffered event still consume memory. Thus it is misleading to call the complete importer constant-memory or compare only parser object sizes.
- Zig integration with quick-xml would require a Rust build and a C-compatible wrapper or equivalent interface; its Rust API is not directly interchangeable with Expat's C API.

### Gaps
- No reliable same-toolchain, same-options linked size or peak-RSS figures for quick-xml versus Expat/pugixml/RapidXML found. Crate download size and source LOC do not answer deployed size.
- No verified broad XML conformance suite result that supports calling it universally more robust than Expat.

## Robustness, defaults, current versions and Calamine configuration

### Takeaway
quick-xml has configurable checking, and versions matter. Calamine intentionally turns off end-name matching, so a speed comparison against stricter settings must state that difference. This does NOT mean Calamine disables every XML syntax check.

### Cited Findings
- Raw current Calamine master identifies itself as 0.37.0 and has `quick-xml = { version = "0.42", features = ["encoding"] }` (line 24 in the file). Search-index GitHub pages returned older 0.36.1/^0.41 snapshots, so use fetched raw source rather than search snippets. [Cargo.toml](https://github.com/tafia/calamine/blob/master/Cargo.toml#L24); [raw](https://raw.githubusercontent.com/tafia/calamine/master/Cargo.toml).
- Current XLSX helper builds a quick-xml `Reader` over a buffered ZIP member. Exact settings from lines 2704-2709 of fetched raw source:
  ```rust
  let mut r = XmlReader::from_reader(BufReader::new(f));
  let config = r.config_mut();
  config.check_end_names = false;
  config.trim_text(false);
  config.check_comments = false;
  config.expand_empty_elements = true;
  ```
  [GitHub line anchor](https://github.com/tafia/calamine/blob/master/src/xlsx/mod.rs#L2704-L2709); [raw file](https://raw.githubusercontent.com/tafia/calamine/master/src/xlsx/mod.rs). These are mutable master links checked 2026-10-21, not pinned commit links.
- Defaults in quick-xml 0.42: end-name matching enabled, comment correctness checking disabled, dangling ampersands prohibited, unmatched closing tags prohibited, empty-element expansion disabled. Calamine changes some defaults, not all. Setting `check_end_names = false` permits mismatched open/close names; it should not be paraphrased as disabling every check. [Config](https://docs.rs/quick-xml/0.42.0/quick_xml/reader/struct.Config.html).
- quick-xml 0.42.0 released 2026-08-22. Changelog exact excerpt: `Reader now validates that input is valid UTF-8 when constructing events.` Non-UTF8 `from_reader` input needs `DecodingReader` and otherwise yields an encoding error. In 0.42 namespaces use a total in-scope bindings cap (128 default), namespace nesting over u16::MAX errors, and Serde deserialization has default recursion limit 128. These latter limits concern namespace resolver/NsReader and Serde APIs, not a claim that plain Calamine Reader enforces those exact limits. [Changelog version section, lines 34 onward](https://github.com/tafia/quick-xml/blob/master/Changelog.md#0420----2026-08-22); [raw](https://raw.githubusercontent.com/tafia/quick-xml/master/Changelog.md).
- Encoding documentation says non-ASCII-compatible encodings (UTF-16BE/LE, ISO-2022-JP) require the `DecodingReader` adapter. Base reader parses UTF8 in 0.42. Be wary of older claims that quick-xml cannot handle UTF16 at all, and of assuming enabling the encoding feature automatically wraps every Reader. [Reader](https://docs.rs/quick-xml/0.42.0/quick_xml/reader/struct.Reader.html); [crate encoding feature](https://docs.rs/quick-xml/0.42.0/quick_xml/#features). The fetched Calamine XLSX file contains no `DecodingReader` string; this alone is insufficient to make sweeping claims about every supported spreadsheet encoding.
- RustSec RUSTSEC-2026-0194 covers quadratic duplicate-attribute checking on hostile tags; patched >=0.41.0. Advisory applies to attribute iteration with default duplicate checks and NsReader; attribute iterators with checks disabled and no NsReader avoid that path. An I/O timeout cannot interrupt the CPU-only loop. This is algorithmic denial of service rather than proof of a memory-corruption flaw. [RustSec](https://rustsec.org/advisories/RUSTSEC-2026-0194.html).

### Inferences
- It is reasonable to regard current quick-xml as actively hardened, not invulnerable because Rust. Recent UTF8, namespace-depth and recursion fixes make old performance/robustness claims potentially stale.
- Calamine's parser settings make sense to disclose in any import benchmark, particularly if Expat is rejecting malformed close tags that Calamine's underlying reader need not reject at that layer. Spreadsheet-specific code may detect other inconsistencies.

### Gaps
- Did not audit every Calamine path or test malformed documents; no conclusion about total Calamine input validation or every encoding should be drawn from the helper alone.

## Speed evidence and limits

### Takeaway
The upstream benchmark infrastructure is useful, but it does not establish quick-xml beating C++ pugixml/RapidXML or C Expat today. No current credible apples-to-apples cross-language measurements were found in this scoped research.

### Cited Findings
- Current compare project uses Criterion and Rust XML alternatives (xml-rs, xmlparser, maybe_xml, rxml, xml_oxide, xml5ever, RustyXML). Its `rapid-xml` crate entry is not evidence of benchmarking the classic C++ RapidXML library. It does not list pugixml or Expat. [compare Cargo.toml](https://raw.githubusercontent.com/tafia/quick-xml/master/compare/Cargo.toml).
- The low-level benchmark counts start/empty tags across 12 XML documents, separates borrowed versus buffered quick-xml, and explicitly sets `check_end_names = false` in both. It does not construct equivalent spreadsheet data, enumerate/unescape all attributes or measure XLSX ZIP handling. A commented-out Rust rapid_xml case says empty-attribute parsing fails. [low-level.rs](https://raw.githubusercontent.com/tafia/quick-xml/master/compare/benches/low-level.rs).
- Compare README explains running `cargo bench` and viewing generated Criterion HTML, but supplies no hardware/version/date results table. [README](https://raw.githubusercontent.com/tafia/quick-xml/master/compare/README.md).
- Project README claims Serde support is around 10x faster than serde-xml-rs; that is a specific author claim about Rust deserialization, with no accompanying current CPU/version benchmark record there. Do not transfer it to Expat, pugixml or RapidXML or quote as a controlled modern ranking. [README performance](https://github.com/tafia/quick-xml#performance).

### Inferences
- Needed fair experiment: same decompressed XLSX XML files, same desired cells and entity/encoding handling, matching validation settings, release builds, total import latency, XML-only latency, allocations and peak RSS, and measured linked-size delta. No benchmark was run for this task.
- For this Zig project, replacing Expat just to obtain quick-xml is not yet justified by a verified performance gain; Calamine would be evaluated as a broader spreadsheet implementation, not solely as an XML engine.

### Gaps
- No quantified current ordering across quick-xml, pugixml, RapidXML and Expat; parent researchers cover the C/C++ sources independently.
