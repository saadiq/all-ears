// The capture A/B driver.
//
// Every other metric in perf.ts answers "how much does X cost". None of them
// answer the question that actually matters — "would this call have been
// smooth without all-ears" — because a call's own conditions (network, tile
// count, who is talking, what else the machine is doing) move far more than
// the extension does. Comparing two different calls is not an experiment.
//
// So this alternates capture on and off within a SINGLE call on a fixed period
// and tags every perf record with the live arm. The two arms then share the
// call's conditions, and `perf.video` split by arm is a controlled comparison
// rather than an anecdote.
//
// The cost is real and is why this defaults off: audio is genuinely not
// recorded during "off" arms. It is a diagnostic mode a person turns on for one
// call, not something to leave running.

/** Arm names, stamped onto perf records as the `arm` tag. */
export type ArmName = "on" | "off";

export interface Arm {
  name: ArmName;
  /** True while capture should be suspended (the "off" arm). */
  suspended: boolean;
  /** 1-based index of this arm within the run, so consecutive on-arms stay
   * distinguishable when the data is grouped. */
  cycle: number;
}

export interface AbDeps {
  setInterval: (fn: () => void, ms: number) => ReturnType<typeof setInterval>;
  clearInterval: (h: ReturnType<typeof setInterval>) => void;
}

/**
 * Alternates arms every `periodMinutes`, starting on the "on" arm so a run that
 * is stopped early has still spent its time capturing rather than not.
 *
 * `onArm` fires once immediately on start (establishing the first arm) and then
 * on each switch. Stopping always restores the "on" arm — a driver that left
 * capture suspended because the flag was cleared mid-off-arm would silently
 * stop recording for the rest of the call.
 */
export class AbExperiment {
  private timer: ReturnType<typeof setInterval> | undefined;
  private cycle = 0;
  private readonly deps: AbDeps;

  constructor(
    private readonly periodMinutes: number,
    private readonly onArm: (arm: Arm) => void,
    deps?: Partial<AbDeps>,
  ) {
    this.deps = {
      setInterval: deps?.setInterval ?? ((fn, ms) => setInterval(fn, ms)),
      clearInterval: deps?.clearInterval ?? ((h) => clearInterval(h)),
    };
  }

  get running(): boolean {
    return this.timer !== undefined;
  }

  start(): void {
    if (this.timer !== undefined) return;
    this.cycle = 0;
    this.advance();
    this.timer = this.deps.setInterval(() => this.advance(), this.periodMinutes * 60_000);
  }

  stop(): void {
    if (this.timer === undefined) return;
    this.deps.clearInterval(this.timer);
    this.timer = undefined;
    // Never leave capture suspended: an aborted experiment must not cost the
    // rest of the call's audio.
    this.onArm({ name: "on", suspended: false, cycle: this.cycle });
  }

  private advance(): void {
    this.cycle += 1;
    const suspended = this.cycle % 2 === 0; // odd cycles capture, even suspend
    this.onArm({ name: suspended ? "off" : "on", suspended, cycle: this.cycle });
  }
}
