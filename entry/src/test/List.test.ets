import localUnitTest from './LocalUnit.test';
import thumbnailPolicyTest from './ThumbnailPolicy.test';

export default function testsuite() {
  localUnitTest();
  thumbnailPolicyTest();
}
