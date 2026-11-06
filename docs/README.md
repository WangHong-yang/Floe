# Floe website

Static website for https://wanghong-yang.github.io/Floe/. GitHub Pages publishes the `docs/` directory from `main`.

Preview from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs
```

Open http://127.0.0.1:8765/ in your browser.

## Publication and search checklist

The canonical URL, social image URLs, structured data and sitemap currently assume https://wanghong-yang.github.io/Floe/. Update all of these if the final domain changes. Do not use a localhost canonical URL.

Before launch:
- Confirm the public website URL and deploy the static files.
- Check the page, download link, social image URL and sitemap from the public URL.
- Add a Visit website link and matching website URL to the repository README and About panel after the site is live.
- Suggested repository description: Offline Chinese & English voice typing for Apple Silicon Macs. Local streaming speech recognition with hotwords.
- Suggested repository topics: macos, apple-silicon, speech-to-text, speech-recognition, dictation, voice-typing, offline, streaming-asr, chinese, swift, sherpa-onnx.
- Verify the site in Google Search Console, submit sitemap.xml, and inspect the homepage. Indexing and rankings are not guaranteed.
- For bilingual search coverage, consider a dedicated Chinese page with translated content and reciprocal hreflang links; do not add hreflang until both pages exist.

Repository metadata and publication are managed separately through GitHub. Software structured data describes the app without fabricated ratings, reviews or licensing claims. Social metadata supports link previews, not a ranking guarantee.
