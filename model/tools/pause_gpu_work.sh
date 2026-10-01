#!/usr/bin/env bash
# Freeze (SIGSTOP) or thaw (SIGCONT) every detached model job on this host: the post_chain /
# run_experiments / run_panel / run_b0_seeds / harmonize_year_test runners and everything under
# them (run_guarded, the trainer, its loader workers, the panel predictor, Rscript). Nothing is
# killed; a frozen run keeps its GPU memory (about 3 GB) and continues from the same step when thawed.
#     model/tools/pause_gpu_work.sh            # freeze
#     model/tools/pause_gpu_work.sh --resume   # thaw (resume_gpu_work.sh does the same)
#     model/tools/pause_gpu_work.sh --status
set -uo pipefail
mode="${1:-pause}"
# Runners were started with setsid, so each has its own process group; signalling the group reaches the whole tree.
pgids=$(ps -eo pgid,args | awk '$2=="bash" && $3 ~ /^model\/tools\/(post_chain|run_experiments|run_panel|run_b0_seeds|harmonize_year_test)/ {print $1}' | sort -u)
if [ -z "$pgids" ]; then echo "no model runners found"; exit 0; fi
for g in $pgids; do
  case "$mode" in
    --resume) kill -CONT -- -"$g" && echo "resumed process group $g";;
    --status) ;;
    *)        kill -STOP -- -"$g" && echo "frozen process group $g";;
  esac
done
sleep 1
echo "state of the job tree (T = stopped, S/R = running):"
ps -eo pgid,pid,stat,etime,args | awk -v want="^($(echo $pgids | tr ' ' '|'))$" '$1 ~ want' | grep -vE "pt_data_worker|sleep" | cut -c1-120
for d in /sys/class/drm/card*/device; do [ -f $d/mem_info_vram_used ] && echo "VRAM used: $(( $(cat $d/mem_info_vram_used)/1024/1024 )) MiB of $(( $(cat $d/mem_info_vram_total)/1024/1024 )) MiB"; done
