# Motion studio: research and design

Docs › Studio makes videos, decks and explainers that move, drawn from the real project. This note
records what the research found about making motion design with frontier models (October 2026) and
what Dante does because of it.

## What the research says

**It's code, not text-to-video.** Opus 5.5 (and GPT-6 Astra) make motion design by writing a
program that draws every frame; a browser renders the frames and an encoder makes the MP4.
Community pipelines use a single HTML file with a `seek(t)` function, HyperFrames (HTML + GSAP,
seeking paused timelines), Remotion (React), Three.js for 3D and Manim for maths. Left to itself,
Opus picks the plain HTML + `seek(t)` route. Dante's runtime is that route, with the capture done by
WebKit in the app instead of Playwright and ffmpeg.

**Determinism is the contract.** Every visible value is a function of time: no `Date.now`,
`requestAnimationFrame` loops, CSS transitions or animations, timers or unseeded randomness.
HyperFrames registers paused timelines and seeks them per frame; breaking the rule fails silently
(empty or early-finished frames). For 3D: build the scene once in setup, update it from `t`, pin
the size and pixel ratio, load every asset before seeking, avoid post-processing that depends on
earlier frames (temporal AA, motion blur from history), and set `AnimationMixer.setTime(t)` for
keyframed models.

**The brief decides the quality.** One-line prompts test the renderer, not the model. Good briefs
lock the format (size, fps, frame count), name the audience and one message, name one visual idea
and a *continuity device* (a shape, colour or motion that links every beat), give art direction
(palette, type, materials, motion language), set a timing bar (beat grid, shot lengths), list
explicit bans, and supply the facts and numbers (models don't check facts). Studios ask 20 or more
questions before starting: problem, audience and what they already know, desired outcome (an
observable change), key messages, where it's shown, format and length, script, references, brand,
mood, deliverables.

**Plan, then build in passes.** The pipelines that look professional plan beats in frame ranges
and approve stills before animating, then build in four passes: blocking (grey boxes, hard cuts),
typography (real copy at size), motion (the same keyframes, eased), finish (palette, texture,
sound last). One studio-style setup splits the work into departments with files as handoffs:
Director (BRIEF.md, storyboard), Art Director (STYLE.md), Animator (source), Render Engineer
(stills, preview), Critic (reviews/findings.md), with approval gates after the storyboard and the
style.

**Review frames, not intentions.** Render stills at every beat start, the frame before it, and the
last frame; lay them out as a contact sheet; critique like a senior motion designer (clipped or
overlapping type, blank frames, one-frame flashes, ghost frames at handoffs, off-token colours,
safe-area violations, static stretches, abrupt endings). The critic works best in a fresh context,
without the builder's reasoning. Each defect gets the smallest local fix, at most two rounds, then
the human decides. Feedback is "what I see, the frame range, what should be true instead".

**Taste rules that recur.**
- One accent, saved for the decision moment; near-black and off-white rather than pure black and
  white; no hue-shifting gradients.
- At most three type sizes; no more than about eight words on screen at once; headlines stay at
  least 30 frames (1.2 s for a short line); short headlines arrive as one unit.
- Ease-out entrances (cubic-bezier(0.16, 1, 0.3, 1)), exits faster than entrances, never linear
  on anything the eye follows; springs with a small overshoot for lively pieces.
- Transitions of 15–25 frames; related staggers of 3–6 frames (above 8 they read as separate
  events); a final hold of at least a second; no blank first frame.
- One dominant action per beat: the hero moves first and the rest responds; cause before effect.
- Text inside a safe margin of about 9% of the width; grain at most about 7%, added last.
- No "AI tells": corner labels, fake timecodes, frame borders, generic spinning objects, invented
  UI where real screens exist.

**Models.** Opus 5.5 leads on motion graphics in Anthropic's own comparison and costs less than
GPT-6 Astra per token; Astra is strong at fast first drafts and layered parallax with depth planes,
and orchestrates other tools (Blender, video models) for assets. Both are worth having: each makes
its own version and the user keeps the better one. Local models and the cloud helpers (Grok, Jev)
don't make motion pieces.

## What Dante does

- **The runtime** (`MotionRuntime`): `dante.scene({ setup, seek })`, seeded `Math.random`,
  `dante.progress/ease/noise`, brand tokens as CSS variables, project data as `dante.data`.
  Scenes are served from their folder by a custom scheme; nothing from the network.
- **Rendering** (`MotionRenderer`): an offscreen WebKit view laid out at the design size, sized so
  WebKit draws exactly the output's pixels (4K is 3840×2160 with the layout still 1920 wide), each
  frame drawn by `renderFrame(t)` and captured, H.264 to 1080p and HEVC for 4K, narration mixed as
  AAC. About 70 frames a second at 1080p and 17 at 4K for a simple scene.
- **Narration**: Kokoro (Dante's natural voice) speaks each line once, measured and placed at its
  time; cached by text, voice and speed.
- **Questions first**: the New piece sheet asks the studio questions (purpose, audience, message,
  format, story, look, motion, sound, data, bans), and the agent then asks what's still open with
  AskUserQuestion before writing anything.
- **Departments as passes**: the brief has the agent write BRIEF.md and storyboard.md (beats in
  seconds and frames, the continuity device, a still per beat), stop for the user's approval of
  the storyboard stills, then build in the four passes, checking stills after each.
- **Self-review**: `motion_frames` renders chosen times plus a contact sheet and returns Dante's
  lint of the scene (timers, wall-clock time, CSS animation, network URLs, raw colours outside the
  brand). The other agent can critique the contact sheet in a fresh context.
- **Two versions**: Claude, Codex or both; with both, the other agent works on its own version in a
  job beside the main one, and Docs shows both to compare.

## Sources

- https://pasqualepillitteri.it/en/news/19007/opus-5-5-motion-design-video-en
- https://aiidelist.com/blog/opus-5-5-motion-design
- https://aiartimind.com/how-to-make-motion-graphics-with-claude-opus-5-5/
- https://opus5video.com/how-to-make-videos-with-claude/
- https://technologiee.substack.com/p/motion-engineering-one-bot-five-departments
- https://charliehills.substack.com/p/claude-code-motion-graphics
- https://apimaster.ai/blog/claude-opus-5-5-video-prompts
- https://hyperframes.heygen.com/guides/hyperframes-vs-remotion
- https://github.com/heygen-com/hyperframes
- https://www.mindstudio.ai/blog/gpt-6-astra-design-websites
- https://bluecarrot.io/blog/tips-for-writing-an-animation-brief-examples-amp-templates/
- https://www.yansmedia.com/blog/corporate-explainer-video-brief-guide
- https://editframe.com/skills/composition/r3f
