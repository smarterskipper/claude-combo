export type Tick = number

declare module 'claude-code' {
  interface PluginState {
    'blue-questions': { tick: Tick }
  }
}
