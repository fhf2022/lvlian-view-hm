import localUnitTest from './LocalUnit.test';
import thumbnailPolicyTest from './ThumbnailPolicy.test';
import imageTransformPolicyTest from './ImageTransformPolicy.test';
import fileSelectionModelTest from './FileSelectionModel.test';
import dragSelectionScrollPolicyTest from './DragSelectionScrollPolicy.test';
import contextMenuPreviewLayoutTest from './ContextMenuPreviewLayout.test';
import thumbnailLoadingTest from './ThumbnailLoading.test';
import nasConnectionTest from './NasConnection.test';
import albumUploadPolicyTest from './AlbumUploadPolicy.test';

export default function testsuite() {
  localUnitTest();
  thumbnailPolicyTest();
  imageTransformPolicyTest();
  fileSelectionModelTest();
  dragSelectionScrollPolicyTest();
  contextMenuPreviewLayoutTest();
  thumbnailLoadingTest();
  nasConnectionTest();
  albumUploadPolicyTest();
}
