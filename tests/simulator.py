"""
Codex Warmup V2 - Simulator Runner
Runs all scenarios through DecisionEngine and prints full score breakdowns & rankings
"""

import json
import os
import sys

# Ensure src/engine is in python path
current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(current_dir)
sys.path.insert(0, os.path.join(project_root, "src", "engine"))

from decision_engine import DecisionEngine

def run_simulation():
    config_file = os.path.join(current_dir, "config.json")
    if not os.path.exists(config_file):
        config_file = os.path.join(project_root, "config", "default.json")
    with open(config_file, "r", encoding="utf-8") as f:
        config = json.load(f)

    scenarios_file = os.path.join(current_dir, "scenarios.json")
    with open(scenarios_file, "r", encoding="utf-8") as f:
        scenarios = json.load(f)

    engine = DecisionEngine(config)

    print("=" * 80)
    print("CODEX WARMUP V2 - DECISION ENGINE OFFLINE SIMULATION")
    print("=" * 80)

    results = {}

    for name, item in scenarios.items():
        state = item["state"]
        desc = item["description"]
        plan = engine.plan_next_action(state)
        results[name] = {
            "description": desc,
            "plan": plan
        }

        print(f"\n[{name}]")
        print(f"Context: {desc}")
        print(f"Now: {state['now']} | Decision: {plan['decision']}")

        if plan["decision"] != "NO_ACTION":
            print(f"  Chosen Time:       {plan['scheduledTime']}")
            print(f"  Expected Boundary: {plan['expectedBoundary']}")
            print(f"  Total Score:       {plan['score']}")
            b = plan["breakdown"]
            print(f"  Score Breakdown:   WorkCoverage={b['workCoverage']} (x{engine.w_work}), "
                  f"BoundaryAlign={b['boundaryAlignment']} (x{engine.w_align}), "
                  f"WakeBenefit={b['wakeBenefit']} (x{engine.w_wake}), "
                  f"ImmediateBonus={b.get('immediateBonus', 0.0)}, "
                  f"SleepPenalty=-{b['sleepDisruption']}, WarmupCost=-{b['warmupCost']}, Risk=-{b['risk']}")
        else:
            print(f"  Reason:            {plan['reason']}")

        print("  Top Candidates:")
        for idx, cand in enumerate(plan.get("topCandidates", [])[:4], 1):
            print(f"    #{idx} Time: {cand['time']} | Score: {cand['totalScore']} | "
                  f"Boundary: {cand['expectedBoundary']} | Align: {cand['boundaryAlignment']} | "
                  f"Coverage: {cand['workCoverage']} | SleepWake: {cand['isSleep']}")

    # Write simulation report
    with open("simulation_report.json", "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print("\nSimulation complete. Report saved to simulation_report.json")

if __name__ == "__main__":
    run_simulation()