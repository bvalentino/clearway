// Copied verbatim from the pinned cmark-gfm 2.1.0 checkout
// (cmark-gfm-core-extensions.h, cmark-gfm-extension_api.h); re-diff these
// against upstream if that pin moves. CLAUDE.md records why they live here.
#ifndef CLEARWAY_BRIDGING_HEADER_H
#define CLEARWAY_BRIDGING_HEADER_H

@import cmark;

void cmark_gfm_core_extensions_ensure_registered(void);
cmark_syntax_extension *cmark_find_syntax_extension(const char *name);
int cmark_parser_attach_syntax_extension(cmark_parser *parser, cmark_syntax_extension *extension);
cmark_llist *cmark_parser_get_syntax_extensions(cmark_parser *parser);

#endif
