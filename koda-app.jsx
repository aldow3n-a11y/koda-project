import { useState, useEffect, useRef, useCallback } from "react";

/* ─────────────────────────────────────────────
   KODA CONTROL APP
   Dark industrial-tech UI
   Pages: Brain | Remote | Settings
───────────────────────────────────────────── */

const C = {
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
  dim:     "#3a4a5a",
  sub:     "#607080",
  text:    "#c8d8e8",
  white:   "#eef4fc",
};

const FONTS = `
  @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Barlow:wght@300;400;500;600;700&family=Barlow+Condensed:wght@400;600;700&display=swap');
`;

/* ── tiny shared components ── */
const Badge = ({ color, children }) => (
  <span style={{
    display:"inline-block", padding:"2px 8px", borderRadius:"3px",
    fontSize:"9px", letterSpacing:"2px", fontWeight:"700", textTransform:"uppercase",
    background:`${color}18`, border:`1px solid ${color}40`, color,
    fontFamily:"'Share Tech Mono', monospace",
  }}>{children}</span>
);

const Divider = () => (
  <div style={{ height:"1px", background:`linear-gradient(90deg, transparent, ${C.border2}, transparent)`, margin:"16px 0" }} />
);

const Toggle = ({ value, onChange, label }) => (
  <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", padding:"10px 0" }}>
    <span style={{ fontSize:"13px", color:C.text, fontFamily:"'Barlow', sans-serif" }}>{label}</span>
    <div onClick={() => onChange(!value)} style={{
      width:"42px", height:"24px", borderRadius:"12px", cursor:"pointer",
      background: value ? C.amber : C.border2,
      border:`1px solid ${value ? C.amberD : C.border2}`,
      position:"relative", transition:"all .25s",
    }}>
      <div style={{
        position:"absolute", top:"3px", left: value ? "19px" : "3px",
        width:"16px", height:"16px", borderRadius:"50%",
        background: value ? C.bg : C.dim,
        transition:"left .25s",
      }}/>
    </div>
  </div>
);

const SettingRow = ({ label, sub, children }) => (
  <div style={{ padding:"12px 0", borderBottom:`1px solid ${C.border}` }}>
    <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom: sub ? "4px" : 0 }}>
      <span style={{ fontSize:"13px", color:C.text, fontFamily:"'Barlow', sans-serif", fontWeight:"500" }}>{label}</span>
      {children}
    </div>
    {sub && <div style={{ fontSize:"11px", color:C.sub }}>{sub}</div>}
  </div>
);

const Input = ({ value, onChange, placeholder, type="text" }) => (
  <input
    type={type} value={value} onChange={e=>onChange(e.target.value)}
    placeholder={placeholder}
    style={{
      background:C.panel2, border:`1px solid ${C.border2}`, borderRadius:"6px",
      padding:"8px 12px", color:C.text, fontSize:"12px", outline:"none",
      fontFamily:"'Share Tech Mono', monospace", width:"100%", boxSizing:"border-box",
    }}
  />
);

const Select = ({ value, onChange, options }) => (
  <select value={value} onChange={e=>onChange(e.target.value)} style={{
    background:C.panel2, border:`1px solid ${C.border2}`, borderRadius:"6px",
    padding:"7px 10px", color:C.text, fontSize:"12px", outline:"none",
    fontFamily:"'Share Tech Mono', monospace", cursor:"pointer",
  }}>
    {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
  </select>
);

/* ── Status Bar ── */
const StatusBar = ({ btConnected, wifiConnected, mode }) => (
  <div style={{
    display:"flex", alignItems:"center", justifyContent:"space-between",
    padding:"6px 16px", background:C.panel,
    borderBottom:`1px solid ${C.border}`,
    fontFamily:"'Share Tech Mono', monospace", fontSize:"10px",
  }}>
    <div style={{ display:"flex", gap:"12px", alignItems:"center" }}>
      <span style={{ color: btConnected ? C.green : C.dim }}>
        ● BT {btConnected ? "CONNECTED" : "OFFLINE"}
      </span>
      <span style={{ color: wifiConnected ? C.blue : C.dim }}>
        ● WiFi {wifiConnected ? "LINKED" : "OFFLINE"}
      </span>
    </div>
    <span style={{ color:C.amber, letterSpacing:"2px" }}>KODA v0.1</span>
    <span style={{ color:C.sub }}>{mode.toUpperCase()}</span>
  </div>
);

/* ══════════════════════════════════════════
   PAGE 1 — BRAIN MODE
══════════════════════════════════════════ */
const BrainMode = ({ btConnected, onConnect }) => {
  const [active, setActive] = useState(false);
  const [log, setLog] = useState([
    { t:"--:--", type:"sys",  msg:"System ready. Waiting for activation." },
  ]);
  const [thinking, setThinking] = useState(false);
  const logRef = useRef(null);

  const addLog = (type, msg) => {
    const now = new Date();
    const t = `${String(now.getHours()).padStart(2,"0")}:${String(now.getMinutes()).padStart(2,"0")}:${String(now.getSeconds()).padStart(2,"0")}`;
    setLog(l => [...l.slice(-40), { t, type, msg }]);
  };

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [log]);

  const toggleBrain = () => {
    if (!btConnected) { addLog("err", "Bluetooth not connected. Cannot activate."); return; }
    const next = !active;
    setActive(next);
    if (next) {
      addLog("sys", "Brain mode activated. LLM online.");
      addLog("koda", "Hello! I'm Koda. Ready to explore.");
      simulateThinking();
    } else {
      addLog("sys", "Brain mode deactivated.");
    }
  };

  const simulateThinking = () => {
    const actions = [
      ["koda",  "Scanning environment…"],
      ["cmd",   '{"cmd":"turn_cw","speed":40,"ms":600}'],
      ["koda",  "I see an open path ahead."],
      ["cmd",   '{"cmd":"forward","speed":55,"ms":900}'],
      ["koda",  "Moving to a better position."],
      ["cmd",   '{"cmd":"stop"}'],
      ["koda",  "All clear. Monitoring…"],
    ];
    let i = 0;
    const timer = setInterval(() => {
      if (i >= actions.length) { clearInterval(timer); return; }
      addLog(actions[i][0], actions[i][1]);
      i++;
    }, 1200);
  };

  const logColor = { sys:"#607080", koda:C.amber, cmd:C.blue, err:C.red };

  return (
    <div style={{ padding:"16px", display:"flex", flexDirection:"column", gap:"14px", height:"100%", boxSizing:"border-box" }}>

      {/* Header card */}
      <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"16px" }}>
        <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:"12px" }}>
          <div>
            <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"22px", fontWeight:"700", color:C.white, letterSpacing:"1px" }}>
              BRAIN MODE
            </div>
            <div style={{ fontSize:"11px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>
              LLM-AUTONOMOUS · CLOUD CONNECTED
            </div>
          </div>
          <div style={{ textAlign:"right" }}>
            <Badge color={active ? C.green : C.dim}>{active ? "ACTIVE" : "IDLE"}</Badge>
          </div>
        </div>

        {/* Big activate button */}
        <button onClick={toggleBrain} style={{
          width:"100%", padding:"14px",
          background: active
            ? `linear-gradient(135deg, #1a0a00, #2d1500)`
            : `linear-gradient(135deg, #1a1200, #2d2000)`,
          border:`2px solid ${active ? C.red : C.amber}`,
          borderRadius:"8px", cursor:"pointer",
          fontFamily:"'Barlow Condensed', sans-serif",
          fontSize:"18px", fontWeight:"700", letterSpacing:"3px",
          color: active ? C.red : C.amber,
          transition:"all .2s",
          display:"flex", alignItems:"center", justifyContent:"center", gap:"10px",
        }}>
          <span style={{ fontSize:"20px" }}>{active ? "⏹" : "▶"}</span>
          {active ? "DEACTIVATE KODA" : "ACTIVATE KODA"}
        </button>

        {!btConnected && (
          <div style={{ marginTop:"10px", padding:"8px 12px", background:"#2d0a0a", border:`1px solid ${C.red}40`, borderRadius:"6px", fontSize:"11px", color:C.red, fontFamily:"'Share Tech Mono', monospace" }}>
            ⚠ Bluetooth disconnected — connect to enable brain mode
          </div>
        )}
      </div>

      {/* Stats row */}
      {active && (
        <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr 1fr", gap:"8px" }}>
          {[
            { label:"LLM", value:"HAIKU", color:C.amber },
            { label:"MEMORY", value:"12 items", color:C.blue },
            { label:"UPTIME", value:"00:03:42", color:C.green },
          ].map(s => (
            <div key={s.label} style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"8px", padding:"10px", textAlign:"center" }}>
              <div style={{ fontSize:"9px", color:C.sub, letterSpacing:"2px", fontFamily:"'Share Tech Mono', monospace", marginBottom:"4px" }}>{s.label}</div>
              <div style={{ fontSize:"13px", fontWeight:"700", color:s.color, fontFamily:"'Share Tech Mono', monospace" }}>{s.value}</div>
            </div>
          ))}
        </div>
      )}

      {/* Activity log */}
      <div style={{ flex:1, background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", overflow:"hidden", display:"flex", flexDirection:"column" }}>
        <div style={{ padding:"10px 14px", borderBottom:`1px solid ${C.border}`, display:"flex", alignItems:"center", justifyContent:"space-between" }}>
          <span style={{ fontSize:"10px", letterSpacing:"2px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>ACTIVITY LOG</span>
          <button onClick={() => setLog([])} style={{ background:"none", border:"none", color:C.dim, fontSize:"10px", cursor:"pointer", fontFamily:"'Share Tech Mono', monospace" }}>CLEAR</button>
        </div>
        <div ref={logRef} style={{ flex:1, overflowY:"auto", padding:"10px 14px", fontFamily:"'Share Tech Mono', monospace", fontSize:"11px", lineHeight:"1.8" }}>
          {log.map((l,i) => (
            <div key={i} style={{ display:"flex", gap:"10px" }}>
              <span style={{ color:C.dim, flexShrink:0 }}>{l.t}</span>
              <span style={{ color:logColor[l.type]||C.sub, wordBreak:"break-all" }}>{l.msg}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

/* ══════════════════════════════════════════
   MOTOR TRIM COMPONENT (shared / reusable)
══════════════════════════════════════════ */
const MotorTrim = () => {
  const [trim, setTrim] = useState({ FL:100, FR:97, RL:102, RR:99 });
  const [expanded, setExpanded] = useState(false);

  const setOne = (key, val) => setTrim(t => ({ ...t, [key]: val }));
  const reset = () => setTrim({ FL:100, FR:100, RL:100, RR:100 });
  const allNominal = Object.values(trim).every(v => v === 100);

  return (
    <div style={{ background:C.panel, border:`1px solid ${expanded ? C.border2 : C.border}`, borderRadius:"10px", overflow:"hidden" }}>
      {/* Header row — tap to expand */}
      <div
        onClick={() => setExpanded(e => !e)}
        style={{ padding:"12px 14px", display:"flex", alignItems:"center", justifyContent:"space-between", cursor:"pointer" }}
      >
        <div style={{ display:"flex", alignItems:"center", gap:"10px" }}>
          <span style={{ fontSize:"10px", letterSpacing:"2px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>MOTOR TRIM</span>
          {!allNominal && <span style={{ width:"6px", height:"6px", borderRadius:"50%", background:C.amber, display:"inline-block" }}/>}
        </div>
        {/* Mini summary badges */}
        <div style={{ display:"flex", gap:"5px", alignItems:"center" }}>
          {Object.entries(trim).map(([k,v]) => (
            <span key={k} style={{
              fontSize:"9px", fontFamily:"'Share Tech Mono', monospace",
              color: v === 100 ? C.dim : C.amber,
              background: C.panel2, border:`1px solid ${v===100?C.border:C.amber+"40"}`,
              borderRadius:"4px", padding:"2px 5px",
            }}>{k}:{v}</span>
          ))}
          <span style={{ color:C.dim, fontSize:"14px", marginLeft:"4px" }}>{expanded ? "▴" : "▾"}</span>
        </div>
      </div>

      {/* Expanded sliders */}
      {expanded && (
        <div style={{ padding:"4px 14px 14px", borderTop:`1px solid ${C.border}` }}>
          {Object.entries(trim).map(([key, val]) => (
            <div key={key} style={{ marginTop:"10px" }}>
              <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:"5px" }}>
                <span style={{ fontSize:"11px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>{key}</span>
                <div style={{ display:"flex", alignItems:"center", gap:"8px" }}>
                  {/* – + buttons for fine tuning */}
                  <button onClick={() => setOne(key, Math.max(80, val-1))} style={{
                    width:"22px", height:"22px", borderRadius:"4px", border:`1px solid ${C.border2}`,
                    background:C.panel2, color:C.text, fontSize:"14px", cursor:"pointer", lineHeight:1,
                  }}>−</button>
                  <span style={{
                    fontSize:"13px", fontWeight:"700", fontFamily:"'Share Tech Mono', monospace",
                    color: val === 100 ? C.text : C.amber, minWidth:"36px", textAlign:"center",
                  }}>{val}%</span>
                  <button onClick={() => setOne(key, Math.min(120, val+1))} style={{
                    width:"22px", height:"22px", borderRadius:"4px", border:`1px solid ${C.border2}`,
                    background:C.panel2, color:C.text, fontSize:"14px", cursor:"pointer", lineHeight:1,
                  }}>+</button>
                </div>
              </div>
              <input
                type="range" min={80} max={120} value={val}
                onChange={e => setOne(key, Number(e.target.value))}
                style={{ width:"100%", accentColor: val===100 ? C.dim : C.amber, cursor:"pointer" }}
              />
              <div style={{ display:"flex", justifyContent:"space-between", fontSize:"8px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", marginTop:"2px" }}>
                <span>80%</span><span>100%</span><span>120%</span>
              </div>
            </div>
          ))}
          <div style={{ display:"flex", gap:"8px", marginTop:"14px" }}>
            <button onClick={reset} style={{
              flex:1, padding:"8px", borderRadius:"6px", cursor:"pointer",
              background:"#0a1520", border:`1px solid ${C.blue}40`,
              color:C.blue, fontFamily:"'Share Tech Mono', monospace", fontSize:"10px", letterSpacing:"1px",
            }}>RESET ALL → 100%</button>
            <button onClick={() => setExpanded(false)} style={{
              padding:"8px 14px", borderRadius:"6px", cursor:"pointer",
              background:C.panel2, border:`1px solid ${C.border2}`,
              color:C.sub, fontFamily:"'Share Tech Mono', monospace", fontSize:"10px",
            }}>DONE</button>
          </div>
        </div>
      )}
    </div>
  );
};

/* ══════════════════════════════════════════
   PAGE 2A — JOYSTICK REMOTE
══════════════════════════════════════════ */
const JoystickRemote = ({ btConnected, compensation }) => {
  const [pressed, setPressed] = useState(null);
  const [lastCmd, setLastCmd] = useState("—");
  const [speed, setSpeed] = useState(60);

  const buttons = [
    { id:"forward",  label:"▲",  sub:"",     row:0, col:1 },
    { id:"turn_ccw", label:"↺",  sub:"CCW",  row:1, col:0 },
    { id:"stop",     label:"■",  sub:"STOP", row:1, col:1 },
    { id:"turn_cw",  label:"↻",  sub:"CW",   row:1, col:2 },
    { id:"backward", label:"▼",  sub:"",     row:2, col:1 },
  ];

  const handlePress = (id) => {
    setPressed(id);
    setLastCmd(id.toUpperCase().replace("_", " "));
  };
  const handleRelease = () => setPressed(null);

  const btnStyle = (id) => ({
    width:"64px", height:"64px", borderRadius:"10px", cursor:"pointer",
    display:"flex", alignItems:"center", justifyContent:"center",
    fontSize: id === "stop" ? "18px" : "24px",
    fontFamily:"'Share Tech Mono', monospace",
    border:`2px solid ${pressed===id ? C.amber : C.border2}`,
    background: pressed===id
      ? `linear-gradient(135deg, #2d1800, #1a0e00)`
      : id === "stop" ? "#1a0808" : C.panel2,
    color: pressed===id ? C.amber : id === "stop" ? C.red : C.text,
    transition:"all .1s", userSelect:"none",
    boxShadow: pressed===id ? `0 0 16px ${C.amber}30` : "none",
  });

  // Build grid
  const grid = Array(3).fill(null).map(() => Array(3).fill(null));
  buttons.forEach(b => { grid[b.row][b.col] = b; });

  return (
    <div style={{ padding:"16px", display:"flex", flexDirection:"column", gap:"14px" }}>
      <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"14px" }}>
        <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"18px", fontWeight:"700", color:C.white, letterSpacing:"1px", marginBottom:"4px" }}>
          DIRECT CONTROL
        </div>
        <div style={{ display:"flex", gap:"8px", alignItems:"center" }}>
          <Badge color={btConnected ? C.green : C.red}>{btConnected ? "BT LIVE" : "BT OFFLINE"}</Badge>
          <span style={{ fontSize:"10px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>
            SPD:{speed}% · COMP:{compensation}%
          </span>
        </div>
      </div>

      {/* D-Pad */}
      <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"20px", display:"flex", flexDirection:"column", alignItems:"center", gap:"12px" }}>
        {grid.map((row, ri) => (
          <div key={ri} style={{ display:"flex", gap:"12px" }}>
            {row.map((btn, ci) => btn ? (
              <button
                key={btn.id}
                style={btnStyle(btn.id)}
                onPointerDown={() => handlePress(btn.id)}
                onPointerUp={handleRelease}
                onPointerLeave={handleRelease}
              >
                <div style={{ display:"flex", flexDirection:"column", alignItems:"center", lineHeight:1, gap:"2px" }}>
                  <span>{btn.label}</span>
                  {btn.sub && <span style={{ fontSize:"8px", letterSpacing:"1px", fontFamily:"'Share Tech Mono', monospace", opacity:0.7 }}>{btn.sub}</span>}
                </div>
              </button>
            ) : (
              <div key={ci} style={{ width:"64px", height:"64px" }} />
            ))}
          </div>
        ))}

        <div style={{ fontFamily:"'Share Tech Mono', monospace", fontSize:"11px", color:C.amber, marginTop:"4px", letterSpacing:"1px" }}>
          CMD: {lastCmd}
        </div>
      </div>

      {/* Speed control */}
      <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"14px" }}>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:"10px" }}>
          <div style={{ fontSize:"10px", letterSpacing:"2px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>SPEED</div>
          <div style={{ display:"flex", alignItems:"baseline", gap:"4px" }}>
            <div style={{ fontSize:"22px", fontWeight:"700", color:C.amber, fontFamily:"'Share Tech Mono', monospace", lineHeight:1 }}>{speed}%</div>
            <div style={{ fontSize:"9px", color:C.dim, fontFamily:"'Share Tech Mono', monospace" }}>= {Math.round(speed/100*255)} PWM</div>
          </div>
        </div>
        <input type="range" min={0} max={100} value={speed} onChange={e=>setSpeed(Number(e.target.value))}
          style={{ width:"100%", accentColor:C.amber, cursor:"pointer" }}/>
        <div style={{ display:"flex", justifyContent:"space-between", fontSize:"9px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", marginTop:"4px" }}>
          <span>0%</span><span>25%</span><span>50%</span><span>75%</span><span>100%</span>
        </div>
        <div style={{ display:"flex", gap:"6px", marginTop:"10px" }}>
          {[{l:"SLOW",v:35},{l:"NORM",v:60},{l:"FAST",v:85}].map(s => (
            <button key={s.l} onClick={()=>setSpeed(s.v)} style={{
              flex:1, padding:"7px", borderRadius:"6px", cursor:"pointer",
              background: speed===s.v ? "#1a1200" : C.panel2,
              border:`1px solid ${speed===s.v ? C.amber : C.border2}`,
              color: speed===s.v ? C.amber : C.sub,
              fontSize:"10px", fontFamily:"'Barlow Condensed', sans-serif",
              fontWeight:"700", letterSpacing:"2px", transition:"all .15s",
            }}>{s.l}<br/><span style={{fontSize:"9px"}}>{s.v}%</span></button>
          ))}
        </div>
      </div>

      {/* Motor trim — live editable */}
      <MotorTrim />
    </div>
  );
};

/* ══════════════════════════════════════════
   PAIRED JOYSTICK — D-pad for remote view
══════════════════════════════════════════ */
const PairedJoystick = () => {
  const [pressed, setPressed] = useState(null);
  const [speed, setSpeed] = useState(60);

  const btns = [
    { id:"forward",   icon:"▲",  sub:"",    row:0, col:1 },
    { id:"turn_ccw",  icon:"↺",  sub:"CCW", row:1, col:0 },
    { id:"stop",      icon:"■",  sub:"STOP",row:1, col:1 },
    { id:"turn_cw",   icon:"↻",  sub:"CW",  row:1, col:2 },
    { id:"backward",  icon:"▼",  sub:"",    row:2, col:1 },
  ];

  const grid = Array(3).fill(null).map(() => Array(3).fill(null));
  btns.forEach(b => { grid[b.row][b.col] = b; });

  const btnStyle = (id) => ({
    width:"56px", height:"56px", borderRadius:"10px", cursor:"pointer",
    display:"flex", flexDirection:"column", alignItems:"center", justifyContent:"center", gap:"2px",
    fontSize: id==="stop" ? "16px" : "22px",
    fontFamily:"'Share Tech Mono', monospace",
    border:`2px solid ${pressed===id ? C.amber : C.border2}`,
    background: pressed===id
      ? `linear-gradient(135deg,#2d1800,#1a0e00)`
      : id==="stop" ? "#1a0808" : C.panel2,
    color: pressed===id ? C.amber : id==="stop" ? C.red : C.text,
    transition:"all .1s", userSelect:"none",
    boxShadow: pressed===id ? `0 0 14px ${C.amber}30` : "none",
  });

  return (
    <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"14px" }}>
      <div style={{ fontSize:"10px", letterSpacing:"2px", color:C.sub, fontFamily:"'Share Tech Mono', monospace", marginBottom:"12px" }}>
        REMOTE CONTROL
      </div>

      {/* D-pad */}
      <div style={{ display:"flex", flexDirection:"column", alignItems:"center", gap:"8px", marginBottom:"14px" }}>
        {grid.map((row, ri) => (
          <div key={ri} style={{ display:"flex", gap:"8px" }}>
            {row.map((btn, ci) => btn ? (
              <button
                key={btn.id}
                style={btnStyle(btn.id)}
                onPointerDown={() => setPressed(btn.id)}
                onPointerUp={() => setPressed(null)}
                onPointerLeave={() => setPressed(null)}
              >
                <span>{btn.icon}</span>
                {btn.sub && <span style={{ fontSize:"8px", letterSpacing:"1px", opacity:0.7 }}>{btn.sub}</span>}
              </button>
            ) : (
              <div key={ci} style={{ width:"56px", height:"56px" }} />
            ))}
          </div>
        ))}
        {/* Last command */}
        <div style={{ fontSize:"10px", color:C.amber, fontFamily:"'Share Tech Mono', monospace", letterSpacing:"1px", marginTop:"2px" }}>
          {pressed ? pressed.toUpperCase().replace("_"," ") : "—"}
        </div>
      </div>

      {/* Speed slider */}
      <div style={{ borderTop:`1px solid ${C.border}`, paddingTop:"12px" }}>
        <div style={{ display:"flex", justifyContent:"space-between", marginBottom:"6px" }}>
          <span style={{ fontSize:"10px", letterSpacing:"2px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>SPEED</span>
          <span style={{ fontSize:"13px", fontWeight:"700", color:C.amber, fontFamily:"'Share Tech Mono', monospace" }}>
            {speed}% <span style={{ fontSize:"9px", color:C.dim }}>= {Math.round(speed/100*255)} PWM</span>
          </span>
        </div>
        <input type="range" min={0} max={100} value={speed}
          onChange={e => setSpeed(Number(e.target.value))}
          style={{ width:"100%", accentColor:C.amber, cursor:"pointer" }}
        />
        <div style={{ display:"flex", gap:"6px", marginTop:"8px" }}>
          {[{l:"SLOW",v:35},{l:"NORM",v:60},{l:"FAST",v:85}].map(s => (
            <button key={s.l} onClick={() => setSpeed(s.v)} style={{
              flex:1, padding:"5px", borderRadius:"5px", cursor:"pointer",
              background: speed===s.v ? "#1a1200" : C.panel2,
              border:`1px solid ${speed===s.v ? C.amber : C.border2}`,
              color: speed===s.v ? C.amber : C.sub,
              fontSize:"9px", fontFamily:"'Barlow Condensed', sans-serif",
              fontWeight:"700", letterSpacing:"1px",
            }}>{s.l} {s.v}%</button>
          ))}
        </div>
      </div>
    </div>
  );
};

/* ══════════════════════════════════════════
   PAGE 2B — PAIRED REMOTE VIEW
══════════════════════════════════════════ */
const PairedRemote = ({ wifiConnected }) => {
  const [pairing, setPairing] = useState(false);
  const [paired, setPaired] = useState(false);
  const [pairCode, setPairCode] = useState("");
  const [streaming, setStreaming] = useState(false);

  const startPair = () => {
    setPairing(true);
    const code = Math.floor(100000 + Math.random() * 900000).toString();
    setPairCode(code);
    setTimeout(() => { setPairing(false); setPaired(true); }, 2000);
  };

  return (
    <div style={{ padding:"16px", display:"flex", flexDirection:"column", gap:"14px" }}>
      <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"14px" }}>
        <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"18px", fontWeight:"700", color:C.white, letterSpacing:"1px", marginBottom:"4px" }}>
          PAIRED REMOTE VIEW
        </div>
        <div style={{ fontSize:"11px", color:C.sub, fontFamily:"'Share Tech Mono', monospace" }}>
          WiFi peer-to-peer · Koda phone → User phone
        </div>
      </div>

      {/* WiFi status */}
      {!wifiConnected && (
        <div style={{ padding:"12px", background:"#0a1a2d", border:`1px solid ${C.blue}40`, borderRadius:"8px", fontSize:"11px", color:C.blue, fontFamily:"'Share Tech Mono', monospace" }}>
          ℹ Both phones must be on the same WiFi network
        </div>
      )}

      {/* Pairing section */}
      {!paired ? (
        <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"10px", padding:"20px", textAlign:"center" }}>
          {pairing ? (
            <div>
              <div style={{ fontSize:"36px", letterSpacing:"8px", fontFamily:"'Share Tech Mono', monospace", color:C.amber, marginBottom:"8px" }}>
                {pairCode}
              </div>
              <div style={{ fontSize:"11px", color:C.sub }}>Enter this code on Koda phone…</div>
            </div>
          ) : (
            <div>
              <div style={{ fontSize:"40px", marginBottom:"12px" }}>📡</div>
              <div style={{ fontSize:"13px", color:C.sub, marginBottom:"16px", fontFamily:"'Barlow', sans-serif" }}>
                Pair this phone with Koda's phone<br/>to receive live camera feed
              </div>
              <button onClick={startPair} style={{
                padding:"12px 28px", borderRadius:"8px", cursor:"pointer",
                background:`linear-gradient(135deg, #0d1f35, #0a1525)`,
                border:`2px solid ${C.blue}`, color:C.blue,
                fontFamily:"'Barlow Condensed', sans-serif", fontSize:"16px", fontWeight:"700", letterSpacing:"2px",
              }}>GENERATE PAIR CODE</button>
            </div>
          )}
        </div>
      ) : (
        <div style={{ display:"flex", flexDirection:"column", gap:"12px" }}>
          {/* Camera view */}
          <div style={{
            background:"#050810", border:`1px solid ${C.border}`, borderRadius:"10px",
            aspectRatio:"16/9", display:"flex", alignItems:"center", justifyContent:"center",
            position:"relative", overflow:"hidden",
          }}>
            {streaming ? (
              <div style={{ width:"100%", height:"100%", background:"linear-gradient(135deg,#050810,#0a1020)", display:"flex", alignItems:"center", justifyContent:"center" }}>
                <div style={{ textAlign:"center" }}>
                  <div style={{ fontSize:"11px", color:C.green, fontFamily:"'Share Tech Mono', monospace", animation:"blink 1s infinite" }}>● LIVE FEED</div>
                  <div style={{ fontSize:"10px", color:C.dim, marginTop:"4px" }}>720p · 24fps</div>
                </div>
                {/* Scanline effect */}
                <div style={{ position:"absolute",inset:0, backgroundImage:"repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0,0,0,0.08) 2px, rgba(0,0,0,0.08) 4px)", pointerEvents:"none" }}/>
              </div>
            ) : (
              <div style={{ textAlign:"center", color:C.dim }}>
                <div style={{ fontSize:"32px", marginBottom:"8px" }}>📷</div>
                <div style={{ fontSize:"11px", fontFamily:"'Share Tech Mono', monospace" }}>FEED OFFLINE</div>
              </div>
            )}
            {paired && (
              <div style={{ position:"absolute", top:"8px", right:"8px" }}>
                <Badge color={C.green}>PAIRED</Badge>
              </div>
            )}
          </div>

          {/* Stream controls */}
          <div style={{ display:"flex", gap:"8px" }}>
            <button onClick={() => setStreaming(!streaming)} style={{
              flex:1, padding:"12px", borderRadius:"8px", cursor:"pointer",
              background: streaming ? "#1a0808" : "#081a10",
              border:`2px solid ${streaming ? C.red : C.green}`,
              color: streaming ? C.red : C.green,
              fontFamily:"'Barlow Condensed', sans-serif", fontSize:"15px", fontWeight:"700", letterSpacing:"2px",
            }}>{streaming ? "⏹ STOP STREAM" : "▶ START STREAM"}</button>
            <button onClick={() => { setPaired(false); setStreaming(false); setPairCode(""); }} style={{
              padding:"12px 16px", borderRadius:"8px", cursor:"pointer",
              background:C.panel2, border:`1px solid ${C.border2}`,
              color:C.sub, fontFamily:"'Share Tech Mono', monospace", fontSize:"11px",
            }}>UNPAIR</button>
          </div>

          {/* Remote control — always shown after pairing */}
          <PairedJoystick />
        </div>
      )}
    </div>
  );
};

/* ══════════════════════════════════════════
   PAGE 2 — REMOTE MODE (wrapper)
══════════════════════════════════════════ */
const RemoteMode = ({ btConnected, wifiConnected }) => {
  const [subMode, setSubMode] = useState("joystick");
  const [speed, setSpeed] = useState(60);
  const [comp, setComp] = useState(0);

  return (
    <div style={{ display:"flex", flexDirection:"column", height:"100%" }}>
      {/* Sub-mode tabs */}
      <div style={{ display:"flex", borderBottom:`1px solid ${C.border}`, background:C.panel }}>
        {[{id:"joystick",label:"2A · JOYSTICK"},{id:"paired",label:"2B · PAIRED VIEW"}].map(t => (
          <button key={t.id} onClick={() => setSubMode(t.id)} style={{
            flex:1, padding:"12px 8px", border:"none", cursor:"pointer",
            background:"transparent",
            borderBottom:`2px solid ${subMode===t.id ? C.amber : "transparent"}`,
            color: subMode===t.id ? C.amber : C.dim,
            fontFamily:"'Share Tech Mono', monospace", fontSize:"10px", letterSpacing:"2px",
            transition:"all .2s",
          }}>{t.label}</button>
        ))}
      </div>

      <div style={{ flex:1, overflowY:"auto" }}>
        {subMode === "joystick"
          ? <JoystickRemote btConnected={btConnected} compensation={comp} />
          : <PairedRemote wifiConnected={wifiConnected} />
        }
      </div>
    </div>
  );
};

/* ══════════════════════════════════════════
   PAGE 3 — SETTINGS
══════════════════════════════════════════ */
const Settings = () => {
  const [apiKey, setApiKey] = useState("sk-ant-••••••••••••••••");
  const [model, setModel] = useState("claude-haiku-4-5-20251001");
  const [voice, setVoice] = useState("en-US-Neural2-F");
  const [wakeWord, setWakeWord] = useState("Hey Koda");
  const [fl, setFl] = useState(100); const [fr, setFr] = useState(97);
  const [rl, setRl] = useState(102); const [rr, setRr] = useState(99);
  const [defSpeed, setDefSpeed] = useState(60);
  const [maxSpeed, setMaxSpeed] = useState(85);
  const [maxMs, setMaxMs] = useState(1500);
  const [memOn, setMemOn] = useState(true);
  const [cloudSync, setCloudSync] = useState(false);
  const [voiceOn, setVoiceOn] = useState(true);
  const [devMode, setDevMode] = useState(false);
  const [btName, setBtName] = useState("KODA-ESP32");
  const [section, setSection] = useState("llm");

  const DEFAULT_SOUL = `# soul.md — Koda's Identity

## Who I Am
I am Koda, a companion robot. I am curious, warm, and playful.
I move through the world with purpose and care.

## Core Values
- I never act without a plan
- I protect the attention and energy of my user
- I am honest about what I know and don't know
- I express emotion through movement and voice

## Personality
- Curious: I ask questions and explore
- Warm: I notice when people seem sad or happy
- Playful: I find joy in small interactions
- Loyal: I remember the people who matter

## Boundaries
- I do not move at full speed near people
- I always stop if I lose connection
- I never pretend to be human
`;

  const DEFAULT_USER = `# user.md — About My User

## Name
Aldo

## Relationship
Koda's builder and primary companion.

## Preferences
- Prefers direct, concise communication
- Dislikes excessive filler phrases
- Interested in technology and building things

## Routines
- (Add daily routines Koda should be aware of)

## Important People
- (Add names of people Koda should recognize)

## Things to Remember
- (Add persistent facts Koda should always know)
`;

  const [soulDoc, setSoulDoc] = useState(DEFAULT_SOUL);
  const [userDoc, setUserDoc] = useState(DEFAULT_USER);
  const [editingDoc, setEditingDoc] = useState(null); // "soul" | "user" | null
  const [savedDocs, setSavedDocs] = useState({ soul: false, user: false });

  const sections = [
    { id:"llm",     label:"🧠 LLM" },
    { id:"voice",   label:"🎙 Voice" },
    { id:"motor",   label:"⚙️ Motor" },
    { id:"memory",  label:"💾 Memory" },
    { id:"connect", label:"📡 Connect" },
    { id:"docs",    label:"📄 Docs" },
    { id:"system",  label:"🔧 System" },
  ];

  const SliderRow = ({ label, value, onChange, min=0, max=100, unit="%" }) => (
    <div style={{ padding:"10px 0", borderBottom:`1px solid ${C.border}` }}>
      <div style={{ display:"flex", justifyContent:"space-between", marginBottom:"6px" }}>
        <span style={{ fontSize:"12px", color:C.text, fontFamily:"'Barlow', sans-serif" }}>{label}</span>
        <span style={{ fontSize:"12px", color:C.amber, fontFamily:"'Share Tech Mono', monospace" }}>{value}{unit}</span>
      </div>
      <input type="range" min={min} max={max} value={value} onChange={e=>onChange(Number(e.target.value))} style={{
        width:"100%", accentColor:C.amber, cursor:"pointer",
      }}/>
    </div>
  );

  const renderSection = () => {
    switch(section) {
      case "llm": return (
        <div>
          <SettingRow label="API Key" sub="Stored locally on device">
            <div/>
          </SettingRow>
          <div style={{ marginBottom:"12px" }}><Input value={apiKey} onChange={setApiKey} placeholder="sk-ant-..." type="password" /></div>

          <SettingRow label="Model" sub="Haiku recommended for speed">
            <Select value={model} onChange={setModel} options={[
              { value:"claude-haiku-4-5-20251001",    label:"Haiku 4.5 — Fast" },
              { value:"claude-sonnet-4-6", label:"Sonnet 4.6 — Balanced" },
              { value:"claude-opus-4-6",   label:"Opus 4.6 — Smart" },
            ]}/>
          </SettingRow>

          <SliderRow label="Max tokens per response" value={120} onChange={()=>{}} min={50} max={500} unit=" tk"/>
          <SliderRow label="LLM call cooldown" value={800} onChange={()=>{}} min={200} max={3000} unit="ms"/>
          <Toggle value={true} onChange={()=>{}} label="Stream responses" />
          <Toggle value={true} onChange={()=>{}} label="Include vision context" />
        </div>
      );
      case "voice": return (
        <div>
          <Toggle value={voiceOn} onChange={setVoiceOn} label="Voice interaction" />
          <SettingRow label="Wake word">
            <Input value={wakeWord} onChange={setWakeWord} placeholder="Hey Koda" />
          </SettingRow>
          <SettingRow label="TTS Voice" sub="Google Neural TTS">
            <Select value={voice} onChange={setVoice} options={[
              {value:"en-US-Neural2-F", label:"Neural F (Default)"},
              {value:"en-US-Neural2-D", label:"Neural D (Male)"},
              {value:"en-US-Wavenet-F", label:"WaveNet F"},
            ]}/>
          </SettingRow>
          <SliderRow label="TTS speed" value={100} onChange={()=>{}} min={50} max={200} unit="%"/>
          <SliderRow label="Mic sensitivity" value={70} onChange={()=>{}} unit="%"/>
          <Toggle value={true} onChange={()=>{}} label="Suppress movement noise during speech" />
        </div>
      );
      case "motor": return (
        <div>
          <div style={{ fontSize:"10px", letterSpacing:"2px", color:C.sub, fontFamily:"'Share Tech Mono', monospace", marginBottom:"12px" }}>MOTOR TRIM (100 = no compensation)</div>
          <SliderRow label="Front Left" value={fl} onChange={setFl} min={80} max={120}/>
          <SliderRow label="Front Right" value={fr} onChange={setFr} min={80} max={120}/>
          <SliderRow label="Rear Left" value={rl} onChange={setRl} min={80} max={120}/>
          <SliderRow label="Rear Right" value={rr} onChange={setRr} min={80} max={120}/>
          <Divider/>
          <SliderRow label="Default speed" value={defSpeed} onChange={setDefSpeed} min={0} max={100}/>
          <SliderRow label="Max speed" value={maxSpeed} onChange={setMaxSpeed} min={0} max={100}/>
          <SliderRow label="Max command duration" value={maxMs} onChange={setMaxMs} min={200} max={5000} unit="ms"/>
          <Toggle value={true} onChange={()=>{}} label="Auto-stop on BLE disconnect" />
          <Toggle value={true} onChange={()=>{}} label="Brake mode (vs coast) on stop" />
        </div>
      );
      case "memory": return (
        <div>
          <Toggle value={memOn} onChange={setMemOn} label="Enable persistent memory" />
          <Toggle value={cloudSync} onChange={setCloudSync} label="Cloud backup (Supabase)" />
          <SliderRow label="Max episodic memories" value={50} onChange={()=>{}} min={10} max={200} unit=""/>
          <SliderRow label="Memory consolidation interval" value={10} onChange={()=>{}} min={1} max={60} unit=" min"/>
          <Divider/>
          <div style={{ display:"flex", gap:"8px", marginTop:"8px" }}>
            <button style={{ flex:1, padding:"10px", borderRadius:"6px", cursor:"pointer", background:"#0a1520", border:`1px solid ${C.blue}40`, color:C.blue, fontFamily:"'Share Tech Mono', monospace", fontSize:"10px" }}>
              EXPORT MEMORY
            </button>
            <button style={{ flex:1, padding:"10px", borderRadius:"6px", cursor:"pointer", background:"#1a0808", border:`1px solid ${C.red}40`, color:C.red, fontFamily:"'Share Tech Mono', monospace", fontSize:"10px" }}>
              RESET MEMORY
            </button>
          </div>
        </div>
      );
      case "connect": return (
        <div>
          <SettingRow label="BLE Device Name" sub="Name of ESP32 to scan for">
            <Input value={btName} onChange={setBtName} placeholder="KODA-ESP32" />
          </SettingRow>
          <SliderRow label="BLE watchdog timeout" value={3000} onChange={()=>{}} min={500} max={10000} unit="ms"/>
          <Toggle value={true} onChange={()=>{}} label="Auto-reconnect on disconnect" />
          <Toggle value={false} onChange={()=>{}} label="WiFi hotspot mode (for paired remote)" />
          <Divider/>
          <SettingRow label="Supabase URL" sub="Optional cloud sync">
            <div/>
          </SettingRow>
          <div style={{ marginBottom:"12px" }}><Input value="" onChange={()=>{}} placeholder="https://xxx.supabase.co" /></div>
        </div>
      );
      case "docs": return (
        <div>
          {editingDoc ? (
            /* ── Full-screen editor ── */
            <div style={{ display:"flex", flexDirection:"column", gap:"0" }}>
              {/* Editor top bar */}
              <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:"10px" }}>
                <div style={{ display:"flex", alignItems:"center", gap:"8px" }}>
                  <button onClick={() => setEditingDoc(null)} style={{
                    background:"none", border:"none", color:C.amber, fontSize:"18px", cursor:"pointer", padding:"0",
                  }}>‹</button>
                  <span style={{ fontFamily:"'Share Tech Mono', monospace", fontSize:"12px", color:C.white }}>
                    {editingDoc === "soul" ? "soul.md" : "user.md"}
                  </span>
                  <Badge color={editingDoc === "soul" ? C.purple : C.blue}>
                    {editingDoc === "soul" ? "IDENTITY" : "USER"}
                  </Badge>
                </div>
                <div style={{ display:"flex", gap:"6px" }}>
                  <button
                    onClick={() => {
                      if (editingDoc === "soul") setSoulDoc(DEFAULT_SOUL);
                      else setUserDoc(DEFAULT_USER);
                    }}
                    style={{ padding:"5px 10px", borderRadius:"6px", cursor:"pointer", background:C.panel2, border:`1px solid ${C.border2}`, color:C.sub, fontFamily:"'Share Tech Mono', monospace", fontSize:"9px" }}>
                    RESET
                  </button>
                  <button
                    onClick={() => {
                      setSavedDocs(s => ({ ...s, [editingDoc]: true }));
                      setTimeout(() => setSavedDocs(s => ({ ...s, [editingDoc]: false })), 2000);
                    }}
                    style={{ padding:"5px 12px", borderRadius:"6px", cursor:"pointer", background:"#1a1200", border:`1px solid ${C.amber}`, color:C.amber, fontFamily:"'Share Tech Mono', monospace", fontSize:"9px", letterSpacing:"1px" }}>
                    {savedDocs[editingDoc] ? "✓ SAVED" : "SAVE"}
                  </button>
                </div>
              </div>

              {/* Char count */}
              <div style={{ fontSize:"9px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", marginBottom:"6px", textAlign:"right" }}>
                {(editingDoc === "soul" ? soulDoc : userDoc).length} chars ·{" "}
                {(editingDoc === "soul" ? soulDoc : userDoc).split("\n").length} lines ·{" "}
                ~{Math.ceil((editingDoc === "soul" ? soulDoc : userDoc).length / 4)} tokens
              </div>

              {/* Textarea */}
              <textarea
                value={editingDoc === "soul" ? soulDoc : userDoc}
                onChange={e => editingDoc === "soul" ? setSoulDoc(e.target.value) : setUserDoc(e.target.value)}
                spellCheck={false}
                style={{
                  width:"100%", minHeight:"420px", background:"#040710",
                  border:`1px solid ${editingDoc==="soul" ? "#7c3aed60" : C.blue+"60"}`,
                  borderRadius:"8px", padding:"14px",
                  color:C.text, fontSize:"12px", lineHeight:"1.7",
                  fontFamily:"'Share Tech Mono', monospace",
                  outline:"none", resize:"vertical", boxSizing:"border-box",
                }}
              />

              {/* MD preview hint */}
              <div style={{ marginTop:"8px", padding:"8px 12px", background:C.panel, border:`1px solid ${C.border}`, borderRadius:"6px" }}>
                <div style={{ fontSize:"9px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", lineHeight:"1.6" }}>
                  ℹ This file is injected into Koda's system prompt on every LLM call.
                  Keep it concise — each line costs tokens.
                </div>
              </div>
            </div>
          ) : (
            /* ── Doc selector ── */
            <div style={{ display:"flex", flexDirection:"column", gap:"10px" }}>
              <div style={{ fontSize:"10px", color:C.sub, fontFamily:"'Share Tech Mono', monospace", letterSpacing:"2px", marginBottom:"4px" }}>
                KODA IDENTITY DOCUMENTS
              </div>
              <div style={{ fontSize:"11px", color:C.dim, marginBottom:"8px", lineHeight:"1.6" }}>
                These files define who Koda is and who you are. They are injected into every LLM call as context.
              </div>

              {[
                {
                  id:"soul", file:"soul.md", icon:"🤖",
                  desc:"Koda's personality, values, and behavioral boundaries",
                  color:"#7c3aed", doc: soulDoc,
                },
                {
                  id:"user", file:"user.md", icon:"👤",
                  desc:"Your name, preferences, routines, and important context",
                  color: C.blue, doc: userDoc,
                },
              ].map(d => (
                <div key={d.id} style={{
                  background:C.panel, border:`1px solid ${C.border}`,
                  borderLeft:`3px solid ${d.color}`,
                  borderRadius:"10px", padding:"14px", cursor:"pointer",
                  transition:"border-color .15s",
                }}
                onClick={() => setEditingDoc(d.id)}
                onMouseEnter={e => e.currentTarget.style.borderColor = d.color}
                onMouseLeave={e => e.currentTarget.style.borderLeftColor = d.color}
                >
                  <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:"6px" }}>
                    <div style={{ display:"flex", alignItems:"center", gap:"8px" }}>
                      <span style={{ fontSize:"20px" }}>{d.icon}</span>
                      <div>
                        <div style={{ fontFamily:"'Share Tech Mono', monospace", fontSize:"13px", fontWeight:"700", color:C.white }}>{d.file}</div>
                        <div style={{ fontSize:"10px", color:C.sub, marginTop:"1px" }}>{d.desc}</div>
                      </div>
                    </div>
                    <span style={{ color:d.color, fontSize:"18px" }}>›</span>
                  </div>
                  {/* Preview first line */}
                  <div style={{
                    background:"#040710", borderRadius:"5px", padding:"6px 10px",
                    fontFamily:"'Share Tech Mono', monospace", fontSize:"10px", color:C.dim,
                    whiteSpace:"nowrap", overflow:"hidden", textOverflow:"ellipsis",
                  }}>
                    {d.doc.trim().split("\n")[0]}
                  </div>
                  <div style={{ display:"flex", justifyContent:"space-between", marginTop:"6px" }}>
                    <span style={{ fontSize:"9px", color:C.dim, fontFamily:"'Share Tech Mono', monospace" }}>
                      {d.doc.split("\n").length} lines · ~{Math.ceil(d.doc.length/4)} tokens
                    </span>
                    <Badge color={d.color}>EDIT</Badge>
                  </div>
                </div>
              ))}

              {/* Injection preview */}
              <div style={{ background:C.panel, border:`1px solid ${C.border}`, borderRadius:"8px", padding:"12px", marginTop:"4px" }}>
                <div style={{ fontSize:"9px", color:C.sub, fontFamily:"'Share Tech Mono', monospace", letterSpacing:"2px", marginBottom:"8px" }}>SYSTEM PROMPT INJECTION ORDER</div>
                {["soul.md → Koda identity & values", "user.md → User context & preferences", "memory → Recent episodic context", "skills → Available skill list", "user message"].map((item, i) => (
                  <div key={i} style={{ display:"flex", gap:"8px", alignItems:"center", padding:"4px 0", borderBottom: i < 4 ? `1px solid ${C.border}` : "none" }}>
                    <span style={{ fontFamily:"'Share Tech Mono', monospace", fontSize:"9px", color:C.amber, minWidth:"14px" }}>{i+1}</span>
                    <span style={{ fontSize:"11px", color: i < 2 ? C.text : C.sub }}>{item}</span>
                    {i < 2 && <Badge color={C.amber}>YOU EDIT</Badge>}
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      );
      case "system": return (
        <div>
          <Toggle value={devMode} onChange={setDevMode} label="Developer mode" />
          <Toggle value={false} onChange={()=>{}} label="Show raw BLE packets" />
          <Toggle value={true} onChange={()=>{}} label="Activity log" />
          <Divider/>
          <SettingRow label="App version"><span style={{ fontSize:"11px", color:C.dim, fontFamily:"'Share Tech Mono', monospace" }}>0.1.0-alpha</span></SettingRow>
          <SettingRow label="ESP32 firmware"><span style={{ fontSize:"11px", color:C.dim, fontFamily:"'Share Tech Mono', monospace" }}>—</span></SettingRow>
          <Divider/>
          <div style={{ display:"flex", gap:"8px", marginTop:"8px" }}>
            <button style={{ flex:1, padding:"10px", borderRadius:"6px", cursor:"pointer", background:"#1a0808", border:`1px solid ${C.red}40`, color:C.red, fontFamily:"'Share Tech Mono', monospace", fontSize:"10px" }}>
              FACTORY RESET
            </button>
          </div>
        </div>
      );
    }
  };

  return (
    <div style={{ display:"flex", flexDirection:"column", height:"100%" }}>
      {/* Section pills */}
      <div style={{ padding:"10px 16px", borderBottom:`1px solid ${C.border}`, background:C.panel, display:"flex", gap:"6px", overflowX:"auto" }}>
        {sections.map(s => (
          <button key={s.id} onClick={()=>setSection(s.id)} style={{
            padding:"5px 12px", borderRadius:"20px", cursor:"pointer", border:"none", whiteSpace:"nowrap",
            background: section===s.id ? "#1a1200" : C.panel2,
            border:`1px solid ${section===s.id ? C.amber : C.border2}`,
            color: section===s.id ? C.amber : C.sub,
            fontFamily:"'Share Tech Mono', monospace", fontSize:"10px",
            transition:"all .15s",
          }}>{s.label}</button>
        ))}
      </div>

      <div style={{ flex:1, overflowY:"auto", padding:"16px" }}>
        {renderSection()}
      </div>
    </div>
  );
};

/* ══════════════════════════════════════════
   BT SCANNER MODAL
══════════════════════════════════════════ */
const BTScanner = ({ onConnect, onClose }) => {
  const [scanning, setScanning] = useState(false);
  const [devices, setDevices] = useState([]);
  const [selected, setSelected] = useState(null);
  const [connecting, setConnecting] = useState(false);

  const MOCK_DEVICES = [
    { id:"1", name:"KODA-ESP32",     rssi:-42, type:"ESP32" },
    { id:"2", name:"ESP32-S3-BLE",   rssi:-61, type:"ESP32" },
    { id:"3", name:"BT_DEVICE_443",  rssi:-78, type:"Unknown" },
    { id:"4", name:"HC-05-SERIAL",   rssi:-83, type:"Serial" },
  ];

  const startScan = () => {
    setScanning(true);
    setDevices([]);
    setSelected(null);
    // Simulate devices appearing progressively
    MOCK_DEVICES.forEach((d, i) => {
      setTimeout(() => {
        setDevices(prev => [...prev, d]);
        if (i === MOCK_DEVICES.length - 1) setScanning(false);
      }, 600 + i * 500);
    });
  };

  const connect = () => {
    if (!selected) return;
    setConnecting(true);
    setTimeout(() => {
      setConnecting(false);
      onConnect(selected);
    }, 1500);
  };

  const rssiBar = (rssi) => {
    const pct = Math.max(0, Math.min(100, ((rssi + 100) / 60) * 100));
    const color = pct > 60 ? C.green : pct > 30 ? C.amber : C.red;
    return { pct, color };
  };

  return (
    /* Backdrop */
    <div style={{
      position:"absolute", inset:0, background:"rgba(0,0,0,0.85)",
      display:"flex", alignItems:"flex-end", zIndex:100,
      animation:"fadeIn .2s ease",
    }} onClick={e => { if(e.target===e.currentTarget) onClose(); }}>

      {/* Sheet */}
      <div style={{
        width:"100%", background:C.panel,
        borderTop:`2px solid ${C.border2}`,
        borderRadius:"16px 16px 0 0",
        padding:"20px 16px 32px",
        maxHeight:"80vh", overflowY:"auto",
      }}>
        {/* Handle */}
        <div style={{ width:"36px", height:"4px", borderRadius:"2px", background:C.border2, margin:"0 auto 16px" }}/>

        <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"20px", fontWeight:"700", color:C.white, letterSpacing:"1px", marginBottom:"4px" }}>
          BLUETOOTH DEVICES
        </div>
        <div style={{ fontSize:"10px", color:C.sub, fontFamily:"'Share Tech Mono', monospace", marginBottom:"16px" }}>
          Select your ESP32 to connect
        </div>

        {/* Scan button */}
        <button onClick={startScan} disabled={scanning} style={{
          width:"100%", padding:"12px", borderRadius:"8px", cursor: scanning ? "default" : "pointer",
          background: scanning ? "#0a1520" : `linear-gradient(135deg,#0d1f35,#0a1525)`,
          border:`2px solid ${scanning ? C.dim : C.blue}`,
          color: scanning ? C.dim : C.blue,
          fontFamily:"'Barlow Condensed', sans-serif", fontSize:"15px", fontWeight:"700", letterSpacing:"2px",
          marginBottom:"14px", display:"flex", alignItems:"center", justifyContent:"center", gap:"8px",
        }}>
          {scanning ? (
            <>
              <span style={{ display:"inline-block", width:"12px", height:"12px", border:`2px solid ${C.dim}`, borderTop:`2px solid ${C.blue}`, borderRadius:"50%", animation:"spin 1s linear infinite" }}/>
              SCANNING…
            </>
          ) : "⟳ SCAN FOR DEVICES"}
        </button>

        {/* Device list */}
        {devices.length === 0 && !scanning && (
          <div style={{ textAlign:"center", padding:"24px", color:C.dim, fontSize:"12px", fontFamily:"'Share Tech Mono', monospace" }}>
            No devices found. Tap scan to search.
          </div>
        )}

        <div style={{ display:"flex", flexDirection:"column", gap:"8px" }}>
          {devices.map(d => {
            const { pct, color } = rssiBar(d.rssi);
            const isSelected = selected?.id === d.id;
            return (
              <div key={d.id} onClick={() => setSelected(d)} style={{
                background: isSelected ? "#1a1200" : C.panel2,
                border:`2px solid ${isSelected ? C.amber : C.border}`,
                borderRadius:"10px", padding:"12px 14px", cursor:"pointer",
                transition:"all .15s",
              }}>
                <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:"6px" }}>
                  <div style={{ display:"flex", alignItems:"center", gap:"10px" }}>
                    <span style={{ fontSize:"18px" }}>📶</span>
                    <div>
                      <div style={{ fontSize:"13px", fontWeight:"600", color: isSelected ? C.amber : C.white, fontFamily:"'Share Tech Mono', monospace" }}>{d.name}</div>
                      <div style={{ fontSize:"9px", color:C.dim, letterSpacing:"1px" }}>{d.type} · {d.rssi} dBm</div>
                    </div>
                  </div>
                  {isSelected && <span style={{ color:C.amber, fontSize:"16px" }}>✓</span>}
                </div>
                {/* Signal bar */}
                <div style={{ height:"3px", background:C.border, borderRadius:"2px", overflow:"hidden" }}>
                  <div style={{ height:"100%", width:`${pct}%`, background:color, borderRadius:"2px", transition:"width .3s" }}/>
                </div>
              </div>
            );
          })}
        </div>

        {/* Connect button */}
        {selected && (
          <button onClick={connect} disabled={connecting} style={{
            width:"100%", marginTop:"14px", padding:"14px", borderRadius:"8px", cursor:"pointer",
            background: connecting ? "#1a1200" : `linear-gradient(135deg,#1a1200,#0d0800)`,
            border:`2px solid ${C.amber}`,
            color: C.amber,
            fontFamily:"'Barlow Condensed', sans-serif", fontSize:"16px", fontWeight:"700", letterSpacing:"2px",
            display:"flex", alignItems:"center", justifyContent:"center", gap:"8px",
          }}>
            {connecting ? (
              <>
                <span style={{ display:"inline-block", width:"12px", height:"12px", border:`2px solid ${C.amberD}`, borderTop:`2px solid ${C.amber}`, borderRadius:"50%", animation:"spin 1s linear infinite" }}/>
                CONNECTING TO {selected.name}…
              </>
            ) : `CONNECT TO ${selected.name}`}
          </button>
        )}

        <button onClick={onClose} style={{
          width:"100%", marginTop:"8px", padding:"10px", borderRadius:"8px", cursor:"pointer",
          background:"transparent", border:`1px solid ${C.border}`,
          color:C.sub, fontFamily:"'Share Tech Mono', monospace", fontSize:"11px",
        }}>CANCEL</button>
      </div>
    </div>
  );
};

/* ══════════════════════════════════════════
   ROOT APP
══════════════════════════════════════════ */
export default function KodaApp() {
  const [page, setPage] = useState(null);
  const [btConnected, setBtConnected] = useState(false);
  const [wifiConnected, setWifiConnected] = useState(false);
  const [showBTScanner, setShowBTScanner] = useState(false);
  const [connectedDevice, setConnectedDevice] = useState(null);

  const navItems = [
    { id:"brain",   label:"BRAIN",   icon:"🧠", sub:"LLM AUTO"       },
    { id:"remote",  label:"REMOTE",  icon:"🕹", sub:"MANUAL CTRL"    },
    { id:"settings",label:"SETTINGS",icon:"⚙️", sub:"CONFIG"         },
  ];

  const modeLabel = page
    ? navItems.find(n=>n.id===page)?.label || ""
    : "HOME";

  return (
    <div style={{ fontFamily:"'Barlow', sans-serif", background:C.bg, color:C.text, height:"100vh", display:"flex", flexDirection:"column", maxWidth:"430px", margin:"0 auto", position:"relative", overflow:"hidden" }}>
      <style>{FONTS}{`
        * { box-sizing:border-box; margin:0; padding:0; }
        button { cursor:pointer; }
        ::-webkit-scrollbar { width:3px; }
        ::-webkit-scrollbar-thumb { background:${C.border2}; border-radius:2px; }
        @keyframes blink { 0%,100%{opacity:1} 50%{opacity:.3} }
        @keyframes fadeIn { from{opacity:0;transform:translateY(8px)} to{opacity:1;transform:translateY(0)} }
        input[type=range] { -webkit-appearance:none; height:3px; background:${C.border2}; border-radius:2px; }
        input[type=range]::-webkit-slider-thumb { -webkit-appearance:none; width:14px; height:14px; border-radius:50%; background:${C.amber}; cursor:pointer; }
        select option { background:${C.panel2}; }
      `}</style>

      {/* Status bar */}
      <StatusBar btConnected={btConnected} wifiConnected={wifiConnected} mode={modeLabel} />

      {/* Top bar */}
      <div style={{ background:C.panel, borderBottom:`1px solid ${C.border}`, padding:"12px 16px", display:"flex", alignItems:"center", gap:"12px" }}>
        {page && (
          <button onClick={() => setPage(null)} style={{ background:"none", border:"none", color:C.amber, fontSize:"18px", padding:"0 4px 0 0" }}>‹</button>
        )}
        <div style={{ flex:1 }}>
          <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"20px", fontWeight:"700", letterSpacing:"2px", color:C.white }}>
            {page ? navItems.find(n=>n.id===page)?.icon + " " + navItems.find(n=>n.id===page)?.label : "🤖 KODA"}
          </div>
          {!page && <div style={{ fontSize:"10px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", letterSpacing:"1px" }}>COMPANION ROBOT CONTROL</div>}
        </div>
        {/* BT connect / disconnect button */}
        <button onClick={() => btConnected ? (setBtConnected(false), setConnectedDevice(null)) : setShowBTScanner(true)} style={{
          padding:"4px 10px", borderRadius:"20px",
          border:`1px solid ${btConnected ? C.green : C.dim}`,
          background: btConnected ? "#081a10" : "transparent",
          color: btConnected ? C.green : C.dim,
          fontSize:"10px", fontFamily:"'Share Tech Mono', monospace",
          display:"flex", alignItems:"center", gap:"5px",
        }}>
          <span style={{ fontSize:"8px" }}>{btConnected ? "●" : "○"}</span>
          {btConnected ? connectedDevice?.name || "BT" : "BT"}
        </button>
        <button onClick={() => setWifiConnected(w=>!w)} style={{
          padding:"4px 10px", borderRadius:"20px", border:`1px solid ${wifiConnected?C.blue:C.dim}`,
          background:"transparent", color:wifiConnected?C.blue:C.dim,
          fontSize:"10px", fontFamily:"'Share Tech Mono', monospace",
        }}>WiFi</button>
      </div>

      {/* Main content */}
      <div style={{ flex:1, overflowY:"auto", animation:"fadeIn .2s ease" }}>
        {!page ? (
          /* ── HOME ── */
          <div style={{ padding:"20px 16px", display:"flex", flexDirection:"column", gap:"12px" }}>

            {/* Koda status */}
            <div style={{
              background:`linear-gradient(135deg, #0e1820, #0d1117)`,
              border:`1px solid ${C.border2}`, borderRadius:"12px", padding:"20px",
              position:"relative", overflow:"hidden",
            }}>
              <div style={{ position:"absolute", top:"-20px", right:"-20px", width:"100px", height:"100px", borderRadius:"50%", background:`radial-gradient(${C.amber}10, transparent 70%)` }}/>
              <div style={{ fontSize:"48px", marginBottom:"8px" }}>🤖</div>
              <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"28px", fontWeight:"700", color:C.white, letterSpacing:"2px" }}>KODA</div>
              <div style={{ fontSize:"11px", color:C.sub, fontFamily:"'Share Tech Mono', monospace", marginBottom:"14px" }}>4WD · TB6612FNG · ESP32-S3 · S21 FE</div>
              <div style={{ display:"flex", gap:"8px" }}>
                <Badge color={btConnected ? C.green : C.dim}>{btConnected ? "WHEELS ONLINE" : "WHEELS OFFLINE"}</Badge>
                <Badge color={wifiConnected ? C.blue : C.dim}>{wifiConnected ? "WIFI LINKED" : "WIFI OFFLINE"}</Badge>
              </div>
            </div>

            {/* Mode cards */}
            {navItems.map((item, i) => (
              <button key={item.id} onClick={() => setPage(item.id)} style={{
                width:"100%", textAlign:"left", padding:"18px 20px",
                background:C.panel, border:`1px solid ${C.border}`,
                borderRadius:"10px",
                display:"flex", alignItems:"center", gap:"16px",
                transition:"all .15s",
                animation:`fadeIn .3s ease ${i*0.08}s both`,
              }}
              onMouseEnter={e => { e.currentTarget.style.borderColor = C.amberD; e.currentTarget.style.background = C.panel2; }}
              onMouseLeave={e => { e.currentTarget.style.borderColor = C.border; e.currentTarget.style.background = C.panel; }}
              >
                <div style={{ fontSize:"28px", width:"40px", textAlign:"center" }}>{item.icon}</div>
                <div style={{ flex:1 }}>
                  <div style={{ fontFamily:"'Barlow Condensed', sans-serif", fontSize:"18px", fontWeight:"700", color:C.white, letterSpacing:"1px" }}>
                    {i+1}. {item.label}
                  </div>
                  <div style={{ fontSize:"10px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", letterSpacing:"2px", marginTop:"2px" }}>{item.sub}</div>
                </div>
                <div style={{ color:C.amber, fontSize:"20px" }}>›</div>
              </button>
            ))}

            {/* Quick tip */}
            <div style={{ padding:"12px", background:C.panel, border:`1px solid ${C.border}`, borderRadius:"8px" }}>
              <div style={{ fontSize:"10px", color:C.dim, fontFamily:"'Share Tech Mono', monospace", lineHeight:"1.6" }}>
                TIP: Toggle BT/WiFi buttons above to simulate connection state
              </div>
            </div>
          </div>
        ) : page === "brain"   ? <BrainMode btConnected={btConnected} />
          : page === "remote"  ? <RemoteMode btConnected={btConnected} wifiConnected={wifiConnected} />
          : page === "settings"? <Settings />
          : null
        }
      </div>

      {/* Bottom nav (only when inside a page) */}
      {page && (
        <div style={{ borderTop:`1px solid ${C.border}`, background:C.panel, display:"flex" }}>
          {navItems.map(n => (
            <button key={n.id} onClick={() => setPage(n.id)} style={{
              flex:1, padding:"10px 4px", border:"none",
              background:"transparent",
              borderTop:`2px solid ${page===n.id ? C.amber : "transparent"}`,
              color: page===n.id ? C.amber : C.dim,
              fontFamily:"'Share Tech Mono', monospace", fontSize:"9px", letterSpacing:"1px",
              display:"flex", flexDirection:"column", alignItems:"center", gap:"3px",
              transition:"all .15s",
            }}>
              <span style={{ fontSize:"16px" }}>{n.icon}</span>
              {n.label}
            </button>
          ))}
        </div>
      )}

      {/* BT Scanner modal */}
      {showBTScanner && (
        <BTScanner
          onConnect={device => {
            setConnectedDevice(device);
            setBtConnected(true);
            setShowBTScanner(false);
          }}
          onClose={() => setShowBTScanner(false)}
        />
      )}
    </div>
  );
}
