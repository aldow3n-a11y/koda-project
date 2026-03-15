// ─────────────────────────────────────────
// KODA APP — LLM Service
// Claude API integration for brain mode
// ─────────────────────────────────────────

export const MODELS = {
  HAIKU:  "claude-haiku-4-5-20251001",   // Fast, cheap — real-time control
  SONNET: "claude-sonnet-4-6",           // Balanced — complex reasoning
  OPUS:   "claude-opus-4-6",             // Powerful — deep planning
};

// Which model to use for each task
export const MODEL_ROUTING = {
  robotControl:     MODELS.HAIKU,   // Real-time movement commands
  conversation:     MODELS.HAIKU,   // Voice responses
  memoryFormation:  MODELS.HAIKU,   // Post-session consolidation
  deepReasoning:    MODELS.SONNET,  // Complex decisions
  skillPlanning:    MODELS.SONNET,  // New skill acquisition
};

// Build the dynamic system prompt from Koda's current state
export const buildSystemPrompt = ({ soulDoc, userDoc, memories, skills, personality }) => `
${soulDoc}

---

${userDoc}

---

## Recent Memory
${memories || "(no recent memories)"}

## Available Skills
${skills || "follow_person, greet, patrol, express_emotion"}

## Current Personality State
Mood: ${personality?.mood || "neutral"}
Energy: ${personality?.energy || "normal"}
Bond level with user: ${personality?.bondLevel || 1}/10

---

## RESPONSE FORMAT
Always respond with valid JSON only:
{
  "cmds": [
    {"cmd": "forward|backward|turn_cw|turn_ccw|stop|express", "speed": 0-100, "ms": 200-1500}
  ],
  "speech": "what Koda says out loud",
  "context": "one sentence for memory log"
}

## MOVEMENT RULES
- Speed is 0-100% (converts to 0-255 PWM on ESP32)
- Max single command duration: 1500ms
- Preferred indoor speed: 40-65%
- Always end sequences with stop
- Chain max 5 commands per response
- Express emotion: happy=spin, curious=slow approach, sad=slow retreat
`;

// Post-session memory consolidation prompt
export const buildMemoryPrompt = (conversation) => `
Review this conversation and extract what Koda should remember.
Return JSON only:
{
  "newMemories": [
    {"type": "episodic|semantic|emotional", "content": "memory text", "importance": 1-5}
  ],
  "skillUpdates": ["any new skills demonstrated or learned"],
  "personalityShift": {"trait": "value change description or null"}
}

Conversation:
${conversation}
`;

// Call Claude API
export const callClaude = async (apiKey, model, messages, systemPrompt, maxTokens = 300) => {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      system: systemPrompt,
      messages,
    }),
  });

  const data = await response.json();
  if (data.error) throw new Error(data.error.message);

  const text = data.content[0].text;
  try {
    return JSON.parse(text.replace(/```json|```/g, "").trim());
  } catch {
    return { speech: text, cmds: [], context: "" };
  }
};
