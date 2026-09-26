import sys
import unittest
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.watch import Subscription, LEASE
from backend import printers


class SubscriptionTests(unittest.TestCase):
    def setUp(self):
        self.cups = Mock()
        self.cups.createSubscription.return_value = 7
        self.cups.getSubscriptions.return_value = [{'notify-subscription-id': 7, 'notify-lease-duration': 120}]
        self.emit = Mock()
        self.schedule = Mock(return_value=23)
        self.cancel = Mock()
        self.monitor = Subscription(lambda: self.cups, self.schedule, self.cancel, self.emit)

    def test_start_requests_push_and_uses_granted_lease(self):
        self.assertTrue(self.monitor.start())
        self.assertEqual(self.cups.createSubscription.call_args.kwargs['recipient_uri'], 'dbus://')
        self.schedule.assert_called_once_with(60, self.monitor.renew)
        self.emit.assert_called_once_with('ready')
        self.cups.getPrinters.assert_not_called()
        self.cups.getJobs.assert_not_called()

    def test_renewal_does_not_read_status(self):
        self.monitor.start()
        self.monitor.renew()
        self.cups.renewSubscription.assert_called_once_with(7, lease_duration=LEASE)
        self.cups.getPrinters.assert_not_called()
        self.cups.getJobs.assert_not_called()

    def test_stop_cancels_timer_and_subscription_once(self):
        self.monitor.start()
        self.monitor.stop()
        self.monitor.stop()
        self.cancel.assert_called_once_with(23)
        self.cups.cancelSubscription.assert_called_once_with(7)

    def test_start_failure_does_not_schedule_polling(self):
        self.cups.createSubscription.side_effect = RuntimeError('denied')
        self.assertFalse(self.monitor.start())
        self.schedule.assert_not_called()
        self.emit.assert_called_once_with('unavailable')

    def test_renewal_failure_attempts_one_recovery(self):
        self.monitor.start()
        self.cups.renewSubscription.side_effect = RuntimeError('gone')
        self.cups.createSubscription.side_effect = RuntimeError('offline')
        self.monitor.renew()
        self.assertEqual(self.cups.createSubscription.call_count, 2)
        self.assertEqual(self.schedule.call_count, 1)
        self.emit.assert_called_with('unavailable')

    def test_missing_lease_does_not_leak_subscription(self):
        self.cups.getSubscriptions.return_value = []
        self.assertFalse(self.monitor.start())
        self.cups.cancelSubscription.assert_called_once_with(7)

    def test_restart_replaces_subscription(self):
        self.monitor.start()
        self.monitor.start()
        self.assertEqual(self.cups.createSubscription.call_count, 2)
        self.cups.cancelSubscription.assert_called_once_with(7)


class LiveStatusTests(unittest.TestCase):
    def test_status_does_not_load_options_or_discover(self):
        cups = Mock()
        cups.queues.return_value = ('Office', [{'name':'Office', 'state':4}])
        helper = Mock()
        backend = printers.PrinterBackend(cups, helper)
        result = printers.dispatch('status', {}, backend)['data']
        self.assertEqual(result['queues'][0]['state'], 4)
        cups.jobs.assert_not_called()
        cups.options.assert_not_called()
        helper.devices.assert_not_called()

    def test_status_reads_only_selected_jobs_and_keeps_queues_on_failure(self):
        cups = Mock()
        cups.queues.return_value = (None, [{'name':'Office'}])
        cups.jobs.side_effect = RuntimeError('unavailable')
        result = printers.PrinterBackend(cups, Mock()).status({'queue':'Office'})
        cups.jobs.assert_called_once_with('Office')
        self.assertEqual(result['queues'], [{'name':'Office'}])
        self.assertEqual(result['jobs'], [])
        self.assertIn('jobsError', result)
