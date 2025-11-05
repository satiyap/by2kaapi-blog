# Hugo Extended (SCSS support) — pinned, reliable
FROM hugomods/hugo:exts

WORKDIR /site
COPY . /site

# Vendor modules for reproducible builds
RUN hugo mod tidy && hugo mod vendor

# Build the static site
RUN hugo --minify
# rebuild Wed Nov  5 15:26:00 IST 2025
