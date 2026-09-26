// Small inline glyphs standing in for the SF Symbols the macOS app uses.

const svg = (body: string, viewBox = "0 0 24 24") =>
  `<svg viewBox="${viewBox}" aria-hidden="true" fill="currentColor">${body}</svg>`;

export const icons = {
  // sparkles
  claude: svg(
    '<path d="M10 2.5l1.9 5.6 5.6 1.9-5.6 1.9L10 17.5l-1.9-5.6L2.5 10l5.6-1.9z"/>' +
      '<path d="M18 13l.95 2.55L21.5 16.5l-2.55.95L18 20l-.95-2.55L14.5 16.5l2.55-.95z"/>',
  ),
  // bolt.fill
  codex: svg('<path d="M13.5 2L4.5 13.5h6L9.5 22l9-11.5h-6z"/>'),
  refresh: svg(
    '<path d="M12 4a8 8 0 1 0 7.75 10h-2.1A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35A7.96 7.96 0 0 0 12 4z"/>',
  ),
  warning: svg('<path d="M12 2.5L1.5 21h21zm-1 7h2v6h-2zm0 7.5h2v2h-2z"/>'),
  plus: svg('<path d="M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7z"/>'),
};
