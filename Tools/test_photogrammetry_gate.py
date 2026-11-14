#!/usr/bin/env python3
"""Focused regression for uniform per-view evidence eligibility; CPU only."""
import copy,unittest
from photogrammetry_calibrated_dataset import decide

def row(view,error,correlation=.7,improvement=20,support=9527,det=1):
    return dict(viewIndex=view,meanRGBL1=error,meanRGBChannelCorrelation=correlation,shuffledImprovementRGB8=improvement,nearestPer4pxCell=support,cameraRotationDeterminant=det)

class GateTests(unittest.TestCase):
    def test_low_error_uncorrelated_control_cannot_win_one_view(self):
        rows={'C2W_+--':[row(i,30) for i in range(3)],'W2C_-+-':[row(0,50),row(1,50),row(2,20,correlation=.129,improvement=2.46,support=193)]}
        result=decide(rows,[0,1,2])
        self.assertTrue(result['accepted']);self.assertEqual(result['selectedConvention'],'C2W_+--')
        self.assertAlmostEqual(result['bestMinusRunnerMarginRGB8'],10)
    def test_no_candidate_passes_when_correlated_candidate_loses_evidence(self):
        rows={'C2W_+--':[row(i,30,correlation=.129) for i in range(3)],'W2C_-+-':[row(i,40,correlation=.129,improvement=2.46) for i in range(3)]}
        self.assertFalse(decide(rows,[0,1,2])['accepted'])
    def test_existing_aggregate_error_and_margin_stay_enforced(self):
        self.assertFalse(decide({'a':[row(i,46) for i in range(3)]},[0,1,2])['accepted'])
        self.assertFalse(decide({'a':[row(i,30) for i in range(3)],'b':[row(i,32) for i in range(3)]},[0,1,2])['accepted'])
    def test_reflections_remain_controls_and_never_win(self):
        result=decide({'a':[row(i,30) for i in range(3)],'reflection':[row(i,1,det=-1) for i in range(3)]},[0,1,2])
        self.assertTrue(result['accepted']);self.assertEqual(result['selectedConvention'],'a')

if __name__=='__main__':unittest.main()
