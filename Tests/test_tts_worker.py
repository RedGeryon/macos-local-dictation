import importlib.util
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "python" / "tts_worker.py"
SPEC = importlib.util.spec_from_file_location("tts_worker", MODULE_PATH)
tts = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = tts
SPEC.loader.exec_module(tts)


class TTSWorkerTests(unittest.TestCase):
    def test_pronunciation_replaces_original_spans_once_and_prefers_longest(self):
        self.assertEqual(
            tts.apply_pronunciation_overrides(
                "Read C++ then C.",
                [{"from": "C", "to": "see"}, {"from": "C++", "to": "C plus plus"}],
            ),
            "Read C plus plus then see.",
        )
        self.assertEqual(
            tts.apply_pronunciation_overrides("A B", [{"from": "A", "to": "B"}, {"from": "B", "to": "C"}]),
            "B C",
        )

    def test_empty_pronunciation_override_array_is_a_no_op_for_live_and_export_text(self):
        live_request = tts.parse_request({
            "text": "Live text remains intact.", "stream": True,
            "pronunciation_overrides": [],
        })
        self.assertEqual(list(tts.request_text_parts(live_request)), ["Live text remains intact."])
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "export.txt"
            source.write_text("Export text remains intact.", encoding="utf-8")
            export_request = tts.parse_request({
                "text_path": str(source), "output_path": str(Path(directory) / "export.wav"),
                "pronunciation_overrides": [],
            })
            self.assertEqual(list(tts.request_text_parts(export_request)), ["Export text remains intact."])

    def test_split_text_prefers_sentence_boundaries(self):
        text = "First sentence is short. This second sentence would fit if a word boundary were chosen instead. Final."
        parts = tts.split_text(text, 80)
        self.assertEqual(parts[0], "First sentence is short.")
        self.assertEqual(" ".join(parts), text)
        self.assertTrue(all(len(part) <= 80 for part in parts))

    def test_split_text_retains_an_unbroken_token(self):
        token = "x" * 200
        parts = tts.split_text(token, 80)
        self.assertEqual("".join(parts), token)
        self.assertEqual([len(part) for part in parts], [80, 80, 40])

    def test_default_preset_is_quality_customvoice(self):
        request = tts.parse_request({"text": "Hello."})
        self.assertEqual(request["voice_id"], "ryan")
        spec, speaker = tts.voice_selection(request)
        self.assertEqual(spec.key, "custom")
        self.assertEqual(speaker, "Ryan")
        self.assertTrue(spec.supports_instruction)

    def test_8bit_choice_selects_its_customvoice_checkpoint(self):
        request = tts.parse_request({"text": "Hello.", "model_id": "qwen-1.7b-8bit"})
        spec, speaker = tts.voice_selection(request)
        self.assertEqual(spec.key, "custom8")
        self.assertEqual(speaker, "Ryan")
        self.assertEqual(spec.repository, "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
        self.assertEqual(spec.revision, "41d3337e8b7f2843a75841595fc14e4b9a7a4b96")

    def test_rejects_unknown_model_choice(self):
        with self.assertRaisesRegex(tts.RequestError, "model_id"):
            tts.parse_request({"text": "Hello.", "model_id": "small-fast-model"})

    def test_voice_design_references_remain_compatible_across_pinned_precisions(self):
        legacy = tts.designed_narrator_reference_key()
        self.assertEqual(legacy, "0c04f403052ad292ac41e90a20a475de335f750b1ce90fd983c554d4e3199683")
        keys = tts.compatible_voice_design_reference_keys("English", "A clear narrator.", 42)
        self.assertEqual(len(keys), 2)
        self.assertIn(
            tts.voice_design_reference_key(tts.MODEL_CATALOG["design"].revision, "English", "A clear narrator.", 42),
            keys,
        )
        self.assertIn(
            tts.voice_design_reference_key(tts.MODEL_CATALOG["design8"].revision, "English", "A clear narrator.", 42),
            keys,
        )

    def test_parent_watchdog_helpers_are_opt_in_and_detect_reparenting(self):
        with patch.dict(tts.os.environ, {}, clear=True):
            self.assertIsNone(tts.configured_parent_pid())
        with patch.dict(tts.os.environ, {"LOCAL_DICTATION_TTS_PARENT_PID": "123"}, clear=True):
            self.assertEqual(tts.configured_parent_pid(), 123)
        with patch.dict(tts.os.environ, {"LOCAL_DICTATION_TTS_PARENT_PID": "not-a-pid"}, clear=True):
            with self.assertRaises(SystemExit):
                tts.configured_parent_pid()
        with patch.object(tts.os, "getppid", return_value=123):
            self.assertTrue(tts.parent_is_current(123))
        with patch.object(tts.os, "getppid", return_value=1):
            self.assertFalse(tts.parent_is_current(123))

    def test_named_designed_narrator_maps_to_the_reviewed_saved_profile(self):
        request = tts.parse_request({
            "text": "Read this.", "voice_id": "designed-narrator", "seed": 999,
        })
        self.assertEqual(request["language"], "English")
        self.assertEqual(request["voice_prompt"], tts.DESIGNED_NARRATOR_PROMPT)
        self.assertEqual(request["seed"], 42)
        spec, speaker = tts.voice_selection(request)
        self.assertEqual(spec.key, "design")
        self.assertIsNone(speaker)
        self.assertEqual(
            tts.designed_narrator_reference_key(),
            "0c04f403052ad292ac41e90a20a475de335f750b1ce90fd983c554d4e3199683",
        )
        with self.assertRaisesRegex(tts.RequestError, "fixed voice"):
            tts.parse_request({"text": "Read this.", "voice_id": "designed-narrator", "voice_prompt": "different"})

    def test_model_is_not_available_until_complete_snapshot_marker_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / tts.MODEL_CATALOG["custom"].directory
            tokenizer = model / "speech_tokenizer"
            tokenizer.mkdir(parents=True)
            (model / "config.json").write_text("{}")
            (model / "weights.safetensors").write_bytes(b"weights")
            (model / "tokenizer_config.json").write_text("{}")
            (model / "vocab.json").write_text("{}")
            (model / "merges.txt").write_text("")
            runtime = tts.QwenRuntime(root)
            self.assertFalse(runtime.installed(tts.MODEL_CATALOG["custom"]))
            (model / ".local-dictation-complete.json").write_text(json.dumps({"repository": tts.MODEL_CATALOG["custom"].repository, "revision": "stale"}))
            self.assertFalse(runtime.installed(tts.MODEL_CATALOG["custom"]))
            (model / ".local-dictation-complete.json").write_text(json.dumps({"repository": tts.MODEL_CATALOG["custom"].repository, "revision": tts.MODEL_CATALOG["custom"].revision}))
            self.assertTrue(runtime.installed(tts.MODEL_CATALOG["custom"]))

    def test_customvoice_uses_exact_model_speaker_identifiers(self):
        for voice_id, expected in (("uncle-fu", "Uncle_Fu"), ("ono-anna", "Ono_Anna")):
            request = tts.parse_request({"text": "Hello.", "voice_id": voice_id})
            _, speaker = tts.voice_selection(request)
            self.assertEqual(speaker, expected)

    def test_rejects_unsupported_speed_instead_of_changing_pitch(self):
        with self.assertRaisesRegex(tts.RequestError, "speed control"):
            tts.parse_request({"text": "Hello.", "speed": 1.25})

    def test_live_requests_require_a_job_directory_at_execution_time(self):
        request = tts.parse_request({"text": "Hello.", "stream": True, "output_path": "/tmp/tts-job"})
        self.assertTrue(request["stream"])
        self.assertEqual(request["output_path"], Path("/tmp/tts-job"))

    def test_job_id_cannot_escape_the_live_job_directory(self):
        for job_id in ("../outside", "/absolute", "has space", "x" * 81):
            with self.assertRaisesRegex(tts.RequestError, "job_id"):
                tts.parse_request({"text": "Hello.", "job_id": job_id})

    def test_file_request_reads_staged_text_in_bounded_parts(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "book.txt"
            source.write_text("First paragraph.\nSecond paragraph with Acme.\n", encoding="utf-8")
            request = tts.parse_request({
                "text_path": str(source), "output_path": str(Path(directory) / "book.wav"),
                "pronunciation_overrides": [{"from": "Acme", "to": "ack me"}],
            })
            self.assertIsNone(request["text"])
            self.assertEqual(list(tts.request_text_parts(request)), ["First paragraph. Second paragraph with ack me."])

    def test_file_request_bounds_one_unbroken_line(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "one-line.txt"
            source.write_text("z" * 20_000, encoding="utf-8")
            request = tts.parse_request({
                "text_path": str(source), "output_path": str(Path(directory) / "book.wav"), "chunk_max_chars": 500,
            })
            parts = list(tts.request_text_parts(request))
            self.assertEqual("".join(parts), "z" * 20_000)
            self.assertTrue(all(len(part) <= 500 for part in parts))

    def test_atomic_wav_publish_and_abort_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "chunk.wav"
            path.write_bytes(b"old")
            writer = tts.AtomicWavWriter(path, 24_000)
            writer.write(b"\x00\x00\x01\x00")
            writer.abort()
            self.assertEqual(path.read_bytes(), b"old")

            writer = tts.AtomicWavWriter(path, 24_000)
            writer.write(b"\x00\x00\x01\x00")
            metadata = writer.finish()
            payload = path.read_bytes()
            self.assertEqual(payload[:4], b"RIFF")
            self.assertEqual(payload[8:12], b"WAVE")
            self.assertEqual(int.from_bytes(payload[40:44], "little"), 4)
            self.assertEqual(metadata, {"bytes": 4, "frames": 2})

    def test_rf64_writer_has_64_bit_ds64_sizes_and_is_atomic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "long.wav"
            writer = tts.AtomicRF64Writer(path, 24_000)
            writer.write(b"\x00\x00" * 3)
            metadata = writer.finish()
            payload = path.read_bytes()
            self.assertEqual(payload[:4], b"RF64")
            self.assertEqual(payload[12:16], b"ds64")
            self.assertEqual(int.from_bytes(payload[28:36], "little"), 6)
            self.assertEqual(int.from_bytes(payload[36:44], "little"), 3)
            self.assertEqual(metadata, {"bytes": 6, "frames": 3})

    def test_cancelled_rf64_writer_leaves_existing_export_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing.wav"
            path.write_bytes(b"previous export")
            writer = tts.AtomicRF64Writer(path, 24_000)
            writer.write(b"\x00\x00" * 10)
            writer.abort()
            self.assertEqual(path.read_bytes(), b"previous export")
            self.assertFalse(path.with_name(path.name + ".partial").exists())

    def test_job_staging_path_is_unique_and_forced_exit_leaves_only_that_path(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing.wav"
            path.write_bytes(b"previous export")
            staging = tts.rf64_staging_path(path, "job_123")
            self.assertEqual(staging.name, ".existing.wav.job_123.partial")
            writer = tts.AtomicRF64Writer(path, 24_000, staging_path=staging)
            writer.write(b"\x00\x00" * 10)
            # Simulate a worker process that exits before `abort`/`finish`.
            writer.file.close()
            self.assertTrue(staging.is_file())
            self.assertEqual(path.read_bytes(), b"previous export")
            staging.unlink()
            self.assertFalse(staging.exists())
            self.assertEqual(path.read_bytes(), b"previous export")

    def test_acknowledgements_are_cumulative_and_keep_memory_bounded(self):
        job = tts.Job("test")
        job.sent = [(0, 0, 0.32), (1, 0, 0.32), (2, 0, 0.32)]
        job.acknowledge(1)
        self.assertEqual(job.sent, [(2, 0, 0.32)])
        self.assertEqual(job.acknowledgements, set())

    def test_backpressure_emits_heartbeat_and_cancel_unblocks_wait(self):
        job = tts.Job("test")
        job.sent = [(0, 0, 11.0)]
        heartbeats: list[bool] = []
        job.cancelled.set()
        with self.assertRaises(tts.Cancelled):
            job.wait_for_capacity(lambda: heartbeats.append(True), heartbeat_interval=0.01)
        self.assertEqual(heartbeats, [])

        job = tts.Job("test")
        job.sent = [(0, 0, 11.0)]
        def cancel_after_heartbeat() -> None:
            heartbeats.append(True)
            job.cancelled.set()
        with self.assertRaises(tts.Cancelled):
            job.wait_for_capacity(cancel_after_heartbeat, heartbeat_interval=0.01)
        self.assertEqual(heartbeats, [True])


if __name__ == "__main__":
    unittest.main()
