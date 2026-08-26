import localUnitTest from './LocalUnit.test';
import thumbnailPolicyTest from './ThumbnailPolicy.test';
import imageTransformPolicyTest from './ImageTransformPolicy.test';

export default function testsuite() {
  localUnitTest();
  thumbnailPolicyTest();
  imageTransformPolicyTest();
}
