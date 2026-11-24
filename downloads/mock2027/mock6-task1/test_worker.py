"""오프라인 학생 확인 문제. 미구현 TODO는 ERROR가 정상이며 50점 채점과 별개입니다."""
import json
import unittest
import worker
from unittest.mock import Mock, patch

class ValidationTests(unittest.TestCase):
    def test_valid_job(self):
        job={"job_id":"exam-001","source_key":"inputs/input.csv","source_version":"real-version"}
        self.assertEqual(worker.validate_job(json.dumps(job)), job)

    def test_invalid_jobs(self):
        base={"job_id":"exam-001","source_key":"inputs/input.csv","source_version":"real-version"}
        values=[[], {}, {"job_id":"bad_id"}, {"source_key":"reports/a.csv"},
                {"source_version":"null"}, {"source_version":""}, {"source_version":123}]
        for change in values:
            value={**base,**change} if isinstance(change,dict) and change else change
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    worker.validate_job(json.dumps(value))

    def test_normal_csv(self):
        raw=b"device,result\npump-1,PASS\npump-2,FAIL\npump-3,PASS\npump-4,PASS\n"
        self.assertEqual(worker.summarize(raw), {"total":4,"pass":3,"fail":1})

    def test_invalid_csv(self):
        values=[b"device,result\n",b"result,device\nPASS,a\n",
                b"device,result\na,UNKNOWN\n",b"device,result\n,PASS\n",
                b"device,result\na,PASS,x\n",b"device,result\n\n",
                b"device,result\n"+b"a,PASS\n"*101,b"x"*65537]
        for raw in values:
            with self.subTest(raw=raw[:30]):
                with self.assertRaises(ValueError):
                    worker.summarize(raw)

class ProcessingOrderTests(unittest.TestCase):
    def setUp(self):
        self.job={"job_id":"exam-001","source_key":"inputs/input.csv","source_version":"v1"}
        self.report={**self.job,"total":4,"pass":3,"fail":1}
        self.message={"Body":"unused","ReceiptHandle":"fake-handle"}
        self.sqs=Mock();self.table=Mock()

    def run_process(self):
        worker.process_message(self.message, Mock(), self.table,
                               self.sqs, "fake-bucket", "fake-url")

    def test_no_delete_when_db_fails(self):
        self.table.put_item.side_effect=RuntimeError("simulated DB failure")
        with patch.object(worker,"validate_job",return_value=self.job), \
             patch.object(worker,"get_or_create_report",return_value=self.report):
            with self.assertRaises(RuntimeError):
                self.run_process()
        self.sqs.delete_message.assert_not_called()

    def test_success_records_before_delete(self):
        calls=[]
        self.table.put_item.side_effect=lambda **kw:calls.append("db")
        self.sqs.delete_message.side_effect=lambda **kw:calls.append("delete")
        with patch.object(worker,"validate_job",return_value=self.job), \
             patch.object(worker,"get_or_create_report",return_value=self.report):
            self.run_process()
        self.assertEqual(calls,["db","delete"])

    def test_conflict_does_not_write_or_delete(self):
        wrong={**self.report,"source_version":"other"}
        with patch.object(worker,"validate_job",return_value=self.job), \
             patch.object(worker,"get_or_create_report",return_value=wrong):
            with self.assertRaises(ValueError):
                self.run_process()
        self.table.put_item.assert_not_called()
        self.sqs.delete_message.assert_not_called()

if __name__ == "__main__":
    unittest.main()
