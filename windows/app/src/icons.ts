// Small inline glyphs standing in for the SF Symbols the macOS app uses.

const svg = (body: string, viewBox = "0 0 24 24") =>
  `<svg viewBox="${viewBox}" aria-hidden="true" fill="currentColor">${body}</svg>`;

export const icons = {
  refresh: svg(
    '<path d="M12 4a8 8 0 1 0 7.75 10h-2.1A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35A7.96 7.96 0 0 0 12 4z"/>',
  ),
  warning: svg('<path d="M12 2.5L1.5 21h21zm-1 7h2v6h-2zm0 7.5h2v2h-2z"/>'),
  cursor: svg('<path d="M5 3l14 8-6 1.8L9.8 19z"/>'),
  pin: svg('<path d="M8 3h8v2h-1v5l3 3v2h-5v6l-1 1-1-1v-6H6v-2l3-3V5H8z"/>'),
  chevron: svg('<path d="M5.4 8.6L12 15.2l6.6-6.6 1.4 1.4-8 8-8-8z"/>'),
  update: svg('<path d="M11 3h2v10.17l3.59-3.58L18 11l-6 6-6-6 1.41-1.41L11 13.17zM5 19h14v2H5z"/>'),
  plus: svg('<path d="M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7z"/>'),
  reset: svg(
    '<path d="M12 4a8 8 0 1 1-7.75 10h2.1A6 6 0 1 0 12 6c-1.66 0-3.14.69-4.22 1.78L11 11H4V4l2.35 2.35A7.96 7.96 0 0 1 12 4z"/>',
  ),
};
