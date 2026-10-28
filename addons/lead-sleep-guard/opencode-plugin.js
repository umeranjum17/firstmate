// Lead sleep guard for OpenCode (installed by juggernaut-addons lead-sleep-guard/install.sh); throwing stops the bash call.
import { guard } from "__GUARD__";

export const JgLeadSleepGuard = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (input?.tool !== "bash") return;
    const reason = guard(output?.args?.command, { dirs: [output?.args?.workdir, directory] });
    if (reason !== null) throw new Error(reason);
  },
});
