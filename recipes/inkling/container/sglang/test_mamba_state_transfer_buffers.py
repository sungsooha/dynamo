import unittest

import torch

from sglang.srt.mem_cache.memory_pool import MambaPool


NUM_LAYERS = 2
NUM_SLOTS = 3


def _pool(temporal: torch.Tensor, num_conv: int = 2) -> MambaPool:
    pool = object.__new__(MambaPool)
    pool.num_mamba_layers = NUM_LAYERS
    pool.conv_slice_axis = 0
    pool.mamba_cache = MambaPool.State(
        conv=[torch.zeros(NUM_LAYERS, NUM_SLOTS, 4, 5) for _ in range(num_conv)],
        temporal=temporal,
    )
    return pool


class TestMambaStateTransferBuffers(unittest.TestCase):
    def test_conv_only_state_advertises_no_empty_buffer(self):
        pool = _pool(torch.zeros(NUM_LAYERS, NUM_SLOTS, 0, 0, 0))
        _, lens, item_lens = pool.get_contiguous_buf_infos()
        self.assertNotIn(0, lens)
        self.assertNotIn(0, item_lens)
        self.assertEqual(len(lens), 2 * NUM_LAYERS)

    def test_temporal_state_is_still_advertised(self):
        pool = _pool(torch.zeros(NUM_LAYERS, NUM_SLOTS, 6, 7, 8))
        _, lens, _ = pool.get_contiguous_buf_infos()
        self.assertNotIn(0, lens)
        self.assertEqual(len(lens), 3 * NUM_LAYERS)

    def test_dims_stay_aligned_with_buffers(self):
        pool = _pool(torch.zeros(NUM_LAYERS, NUM_SLOTS, 0, 0, 0))
        _, lens, _ = pool.get_contiguous_buf_infos()
        self.assertEqual(len(pool.get_state_dim_per_tensor()), len(lens))


if __name__ == "__main__":
    unittest.main()
