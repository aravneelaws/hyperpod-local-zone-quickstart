# Smoke tests

Run these **from the controller node** after SSHing into the cluster. They assume:
- Slurm partition `ml.p5e.48xlarge` with at least 2 nodes (adjust `-p` if your partition is named differently)
- FSx Lustre mounted at `/fsx/`

Order:

1. `00-verify-environment.sh` — Not an sbatch. Run interactively to confirm sinfo, GPUs, EFA adapters, FSx mount, and NCCL binary paths.
2. `01-nccl-single-node.sbatch` — Intra-node NCCL all-reduce across 8 GPUs on one node. Exercises NVSwitch, no EFA. `sbatch 01-nccl-single-node.sbatch`
3. `02-nccl-2-node.sbatch` — Cross-node NCCL all-reduce across 16 GPUs. Exercises EFA multi-rail. `sbatch 02-nccl-2-node.sbatch`
4. `03-pytorch-ddp.sbatch` — Multi-node PyTorch DDP smoke test. **Prereq**: torch venv on `/opt/dlami/nvme/venv-ddp` on each worker (see script header).

Outputs go to `logs/<job-name>-<jobid>.out` in whichever directory you submit from. `../results/` in this repo contains representative outputs from a working run.
