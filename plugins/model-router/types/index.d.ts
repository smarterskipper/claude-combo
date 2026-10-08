export type ModelKey = 'haiku' | 'sonnet' | 'opus' | 'fable'
export type Effort = 'low' | 'medium' | 'high' | 'xhigh' | 'max'
export type Mode = 'auto' | 'pinned' | 'off'

export type Decision = {
  /** Rung on the 20-step ladder: model-major, effort-minor, cheapest first. */
  rung: number
  reason: string
  source: 'heuristic' | 'haiku' | 'pinned' | 'escalated' | 'held' | 'session'
}

export type HistoryEntry = {
  /** Start of the prompt, one line. */
  text: string
  /** Rung the turn finished on; null until it completes. */
  rung: number | null
  costUsd: number | null
  /** The next prompt said this turn was wrong. */
  rejected: boolean
  /** This prompt said the last turn was wrong, so it was stepped up. */
  redo: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'model-router': {
      mode: Mode
      decision: Decision | null
      /** The rung the last main-loop request actually ran on. */
      active: number | null
      lastTurn: { rung: number; costUsd: number; endedAt: number } | null
      sessionUsd: number
      /** Rung the person pinned with /route pin. */
      pin: number
      /** Last few prompts, oldest first. */
      history: HistoryEntry[]
    }
  }
}
