# Sample results

These are the actual outputs from a working run in Phoenix Local Zone (`us-west-2-phx-2a`) with 2× `ml.p5e.48xlarge` (H200) and 1× `ml.m6i.4xlarge` controller.

- `nccl-1node-5.out` — Single-node NCCL all-reduce across 8 H200 GPUs. Peaks at ~476 GB/s busBw at 4 GB (NVSwitch-limited).
- `nccl-2node-6.out` — 2-node NCCL all-reduce across 16 GPUs. Peaks at ~484 GB/s busBw at 16 GB. Uses EFA multi-rail across both nodes.
- `ddp-train-11.out` — PyTorch DDP: 100 training steps of a ~440M-parameter MLP in 3.2s, ~16,239 samples/sec across 16 GPUs.

Private IPv4 addresses (10.42.x.y) and short hostnames in these logs are RFC 1918 addresses from our VPC and are not sensitive.
