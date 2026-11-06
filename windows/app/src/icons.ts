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
  gear: svg('<path fill-rule="evenodd" d="M10.13 4.22 L10.60 1.59 L13.40 1.59 L13.87 4.22 L16.18 5.18 L18.37 3.65 L20.35 5.63 L18.82 7.82 L19.78 10.13 L22.41 10.60 L22.41 13.40 L19.78 13.87 L18.82 16.18 L20.35 18.37 L18.37 20.35 L16.18 18.82 L13.87 19.78 L13.40 22.41 L10.60 22.41 L10.13 19.78 L7.82 18.82 L5.63 20.35 L3.65 18.37 L5.18 16.18 L4.22 13.87 L1.59 13.40 L1.59 10.60 L4.22 10.13 L5.18 7.82 L3.65 5.63 L5.63 3.65 L7.82 5.18 Z M15.40 12.00 A3.4 3.4 0 1 0 8.60 12.00 A3.4 3.4 0 1 0 15.40 12.00 Z"/>'),
  close: svg('<path d="M6.4 5L12 10.6 17.6 5 19 6.4 13.4 12l5.6 5.6-1.4 1.4-5.6-5.6L6.4 19 5 17.6l5.6-5.6L5 6.4z"/>'),
  infinity: svg(
    '<path fill="none" stroke="currentColor" stroke-width="3.4" stroke-linejoin="round" d="M24 12C20 6.5 16 3 11 3a9 9 0 0 0 0 18c5 0 9-3.5 13-9s8-9 13-9a9 9 0 0 1 0 18c-5 0-9-3.5-13-9z"/>',
    "0 0 48 24",
  ),
  reset: svg(
    '<path d="M12 4a8 8 0 1 1-7.75 10h2.1A6 6 0 1 0 12 6c-1.66 0-3.14.69-4.22 1.78L11 11H4V4l2.35 2.35A7.96 7.96 0 0 1 12 4z"/>',
  ),
};
