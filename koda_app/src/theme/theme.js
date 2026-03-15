// ─────────────────────────────────────────
// KODA APP — Theme
// ─────────────────────────────────────────

export const C = {
  bg:      "#090b0e",
  panel:   "#0e1117",
  panel2:  "#13181f",
  border:  "#1c2530",
  border2: "#253040",
  amber:   "#f59e0b",
  amberD:  "#d97706",
  amberL:  "#fcd34d",
  red:     "#ef4444",
  green:   "#22c55e",
  blue:    "#3b82f6",
  purple:  "#7c3aed",
  dim:     "#3a4a5a",
  sub:     "#607080",
  text:    "#c8d8e8",
  white:   "#eef4fc",
};

export const FONTS = `
  @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Barlow:wght@300;400;500;600;700&family=Barlow+Condensed:wght@400;600;700&display=swap');
`;

export const GLOBAL_CSS = `
  * { box-sizing:border-box; margin:0; padding:0; }
  button { cursor:pointer; }
  ::-webkit-scrollbar { width:3px; }
  ::-webkit-scrollbar-thumb { background:${C.border2}; border-radius:2px; }
  @keyframes blink { 0%,100%{opacity:1} 50%{opacity:.3} }
  @keyframes fadeIn { from{opacity:0;transform:translateY(8px)} to{opacity:1;transform:translateY(0)} }
  @keyframes spin { to{transform:rotate(360deg)} }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.4} }
  input[type=range] { -webkit-appearance:none; height:3px; background:${C.border2}; border-radius:2px; }
  input[type=range]::-webkit-slider-thumb { -webkit-appearance:none; width:14px; height:14px; border-radius:50%; background:${C.amber}; cursor:pointer; }
  select option { background:${C.panel2}; }
`;
