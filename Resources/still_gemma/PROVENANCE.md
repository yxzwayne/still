# Gemma text runtime provenance

The reference is the installed [MLX-VLM 0.8.0 release](https://pypi.org/project/mlx-vlm/0.8.0/). The file hashes below use the Base64url SHA-256 format from the wheel's `RECORD`.

| Still file | Path in the MLX-VLM wheel | SHA-256 |
| --- | --- | --- |
| `model.py` | `mlx_vlm/models/gemma4/language.py` | `EbGL5lL1cFKbtf1-bff3iEVsyLd6CUP91KVZHfwlQQY` |
| `model.py` | `mlx_vlm/models/gemma4_unified/config.py` | `tb4LedbiyyuqdTJWwsRrWQp9Qys8a9_OBmC8NmjHp4c` |
| `model.py` | `mlx_vlm/models/rope_utils.py` | `aUT2mgPEHLuWE6-9LxtUtxxQSECq6w6t45xhCdv90ls` |
| `cache.py` | `mlx_vlm/models/cache.py` | `Wm9_6sUkhivYFpcQMU9Yb38DPqj7MDwk1x6XE6WP9ws` |
| `sampling.py` | `mlx_vlm/sample_utils.py` | `-glbFsVHUfGTrFNpqvz6LHtsc1TsvLZjnT7ewiYqjBc` |
| `tokenizer.py` | `mlx_vlm/tokenizer_utils.py` | `iZ0tCaBjRjDVO41n7auybIEUTNy5kj5GZmfMTxHwd4A` |

Still adapts the dense Unified text forward pass, full and sliding attention, RoPE, single-sequence KV caches, top-p/top-k sampling and SentencePiece streaming decoder. The loader uses MLX for the checkpoint's indexed safetensors and affine 4-bit quantization. The tokenizer and official chat template load from the local checkpoint with Tokenizers and Jinja2.

The [pinned checkpoint](https://huggingface.co/mlx-community/gemma-4-12B-it-4bit/tree/73bcf09092aa277861d5a191b989b666f7f32e8f) lives outside the app bundle. The code notices are in [LICENSE](LICENSE) and [LICENSE-Apple](LICENSE-Apple).
