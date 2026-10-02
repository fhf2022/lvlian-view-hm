import localUnitTest from './LocalUnit.test';
import thumbnailPolicyTest from './ThumbnailPolicy.test';
import imageTransformPolicyTest from './ImageTransformPolicy.test';
import fileSelectionModelTest from './FileSelectionModel.test';
import dragSelectionScrollPolicyTest from './DragSelectionScrollPolicy.test';

export default function testsuite() {
  localUnitTest();
  thumbnailPolicyTest();
  imageTransformPolicyTest();
  fileSelectionModelTest();
  dragSelectionScrollPolicyTest();
}
