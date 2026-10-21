# Expat, libxml2 and smaller Rust alternatives

## How do their capabilities and robustness compare?

### Takeaway
Expat is a C streaming parser appropriate for extracting values without a document tree. libxml2 supplies a much broader XML toolkit. roxmltree is a Rust read-only tree; xmlparser is a deliberately incomplete tokenizer, so its compactness is not equivalent functionality.

### Cited Findings
- Expat uses callbacks and accepts incremental input, enabling documents larger than RAM; optional namespace processing expands names. Its current API has configurable entity amplification, allocation amplification and reparse-deferral protections. — [Expat API](https://libexpat.github.io/doc/api/latest/)
- libxml2 offers SAX callbacks and DOM parsing, DTD validation, external resource controls and entity expansion limits. Its `XML_PARSE_NO_XXE` option (since 2.13.0) disables external DTD/entity loading. `XML_PARSE_NOENT` actually enables entity substitution and external loading; `XML_PARSE_NONET` is not a complete XXE defense and has no built-in client effect since removal of the last network client in 2.15. — [Parser API](https://gnome.pages.gitlab.gnome.org/libxml2/html/parser_8h.html)
- libxml2 also provides a streaming pull reader, XPath and XSD validation APIs. — [Reader API](https://gnome.pages.gitlab.gnome.org/libxml2/html/xmlreader_8h.html), [XPath API](https://gnome.pages.gitlab.gnome.org/libxml2/html/xpath_8h.html), [Schema API](https://gnome.pages.gitlab.gnome.org/libxml2/html/xmlschemas_8h.html)
- roxmltree builds a read-only tree, resolves namespaces and references, preserves positions, accepts UTF-8, has no dependencies or unsafe code, and lacks tree modification/writing/full DTD support. — [Upstream README](https://github.com/RazrFalcon/roxmltree)
- roxmltree 0.21.1 rejects nonempty DTD by default for security, still checks billion-laughs expansion, offers a node count limit (default effectively unlimited) and an optional external entity resolver. — [ParsingOptions](https://docs.rs/roxmltree/latest/roxmltree/struct.ParsingOptions.html)
- xmlparser supplies borrowed token positions, no allocations/dependencies and UTF-8 only, but does not check matching tree structure or duplicate attributes. Its authors call it a low-level tokenizer not intended for direct use. It forbids unsafe code, but callers must supply structural correctness checks. — [Upstream README](https://github.com/RazrFalcon/xmlparser)
- XML well-formedness (matching tags, legal structure/characters) and document validity against declarations are separate concepts in the standard. XSD validation is an additional schema mechanism, illustrated by libxml2's separate validation API. — [W3C XML](https://www.w3.org/TR/xml/), [XSD API](https://gnome.pages.gitlab.gnome.org/libxml2/html/xmlschemas_8h.html)
- Expat does not fetch external URLs/files by default; application-provided external entity handlers enable that possibility. XXE and denial of service are distinct: expansion limits do not make arbitrary external resource access safe. Current documented billion-laughs defaults stop expansion exceeding both 100x input and 8 MiB; protection arrived in 2.4.0, deep-recursion fixes in 2.7.0 and allocation protection in 2.7.2. — [Expat security](https://libexpat.github.io/doc/xml-security/)
- As of 2026-10-21 upstream lists Expat 2.9.0, released October 5 with security fixes; this is upstream status, not a claim about the app's pinned version. — [Expat home](https://libexpat.github.io/)

### Inferences
- Rust memory safety and XML semantic correctness are different properties: xmlparser demonstrates that a safe tokenizer can accept malformed document nesting. Source above.
- For XLSX extraction, comparing streaming Expat or quick-xml against a fully built tree does not isolate tokenization speed; application extraction/allocation costs also matter. Architecture sources above.
- libxml2's extra features should be selected for requirements, not assumed to increase robustness automatically: options that enable external loading/DTD validation alter attack surface. Parser API above explicitly warns DTD validation is unsuitable for untrusted input.

### Gaps
- No runtime/security audit of this app's Expat configuration was performed; do not infer vulnerability or safety from library name alone.
- No direct claim here about pugixml/RapidXML: covered by sibling researcher.

## What speed evidence is actually comparable?

### Takeaway
Available upstream measurements demonstrate workload-dependent results, not a universal winner. The roxmltree suite is useful reproducible evidence but tests an old quick-xml dependency and mixes different feature levels.

### Cited Findings
- roxmltree's upstream Apple M1 Pro measurements show quick-xml taking 1.250 ms versus roxmltree 1.495 ms for its large case and 0.206 ms versus 0.421 ms for medium; its huge tree comparison gives roxmltree 2.998 ms versus libxml2 6.851 ms. The author warns implementations provide different XML support; libxml2 is measured through a Rust wrapper. — [Benchmark README](https://raw.githubusercontent.com/RazrFalcon/roxmltree/master/README.md)
- The benchmark manifest currently pins quick-xml `0.30`, xml-rs `0.8`, xmltree `0.10` and optional libxml wrapper `0.3.1`; these README numbers cannot be represented as a current all-library ranking. — [Benchmark manifest](https://raw.githubusercontent.com/RazrFalcon/roxmltree/master/benches/Cargo.toml)

### Inferences
- These data support quick-xml being competitive for streaming reads and roxmltree being competitive for read-only tree construction in those cases. They cannot establish superiority over current Expat, pugixml or RapidXML, or predict full XLSX import time.
- A fair app benchmark should consume equal cells/strings, check identical outputs, separately measure ZIP decompression and XML extraction, and report peak memory, parser options, versions, machine and build flags.

### Gaps
- No current primary-source benchmark found in this focused pass testing all six libraries on identical semantics and settings.
- No app benchmark was run and no app source changed.

## How should size claims be interpreted?

### Takeaway
Published source size and dependency counts are not executable-size measurements. A useful size comparison must measure the same tiny application linked to each parser under the same build options.

### Cited Findings
- xmlparser upstream reports approximately 1,400 lines and approximately 30 KiB in a release build according to cargo-bloat, plus zero dependencies. The README does not give enough target/link/configuration details to promise that app increment. — [xmlparser README](https://github.com/RazrFalcon/xmlparser)
- roxmltree's dependency count is zero and it allocates a read-only tree; tree memory depends on nodes, attributes and normalized strings, not simply input bytes. These describe dependencies/runtime memory, not linked code size. — [roxmltree README](https://raw.githubusercontent.com/RazrFalcon/roxmltree/master/README.md)

### Inferences
- libxml2 is functionally broader than these focused alternatives, but a precise static executable size ordering would require measurement with enabled features and linker dead stripping documented.
- Adding quick-xml/roxmltree to Zig means Rust build/FFI integration in addition to XML code; a dependency-free Rust crate is not equivalent to a dependency-free Zig build.

### Gaps
- No apples-to-apples stripped binary or static-library size measurements were found or produced for Expat/libxml2/quick-xml/roxmltree/pugixml/RapidXML.
- Source archives, installed distribution packages, static archives and linked executable increments must not be compared as interchangeable quantities.
