// Small inline glyphs standing in for the SF Symbols the macOS app uses.

const svg = (body: string, viewBox = "0 0 24 24") =>
  `<svg viewBox="${viewBox}" aria-hidden="true" fill="currentColor">${body}</svg>`;

export const icons = {
  refresh: svg(
    '<path d="M12 4a8 8 0 1 0 7.75 10h-2.1A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35A7.96 7.96 0 0 0 12 4z"/>',
  ),
  warning: svg('<path d="M12 2.5L1.5 21h21zm-1 7h2v6h-2zm0 7.5h2v2h-2z"/>'),
  plus: svg('<path d="M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7z"/>'),
};
