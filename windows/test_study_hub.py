import unittest
from unittest.mock import patch

import study_hub


class StudyHubTests(unittest.TestCase):
    def test_fetch_etl_keeps_source_deadline_and_late_window(self):
        courses = [{"id": 1, "name": "자료구조"}]
        assignments = [{
            "name": "과제 1", "due_at": "2026-09-30T14:00:00Z",
            "lock_at": "2026-10-02T14:00:00Z",
            "html_url": "https://myetl.snu.ac.kr/courses/1/assignments/2",
        }]
        with patch.object(study_hub, "request_json", side_effect=[courses, assignments]) as request:
            result = study_hub.fetch_etl("test-token")
        self.assertEqual(result[0]["due_at"], "2026-09-30T14:00:00Z")
        self.assertEqual(result[0]["lock_at"], "2026-10-02T14:00:00Z")
        self.assertEqual(request.call_count, 2)
        self.assertTrue(all(call.kwargs["token"] == "test-token" for call in request.call_args_list))

    def test_local_model_sends_no_api_key(self):
        with patch.object(study_hub, "request_json", return_value={"response": "과제 마감 확인"}) as request:
            output = study_hub.generate_briefing("과제 공지", backend="Ollama", base_url="http://127.0.0.1:11434", model="qwen3:4b", api_key="unused")
        self.assertEqual(output, "과제 마감 확인")
        self.assertNotIn("token", request.call_args.kwargs)

    def test_api_sends_only_supplied_text(self):
        response = {"choices": [{"message": {"content": "할 일 정리"}}]}
        with patch.object(study_hub, "request_json", return_value=response) as request:
            output = study_hub.generate_briefing("수업 공지", backend="API", base_url="https://example.org/v1", model="model", api_key="secret")
        self.assertEqual(output, "할 일 정리")
        self.assertEqual(request.call_args.kwargs["token"], "secret")
        self.assertEqual(request.call_args.kwargs["payload"]["messages"][1]["content"], "수업 공지")


if __name__ == "__main__":
    unittest.main()
