#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Adds a Block pill to the now-playing action row as a real item of the row.
//
// The row is a Texture ASCollectionView fed by an IGListKit
// ELMCollectionNodeSingleSectionController. That controller owns a mutable
// `_cellNodes` array; `numberOfItems` is its count, `viewModelsForObject:`
// returns a copy of it, and the app's own -insertNode:atIndex: / -setNodes:
// just edit it and call -update so IGListKit diffs old vs new view models.
// We add our ASCellNode to that array at the moment the controller builds its
// view models, so the app's own diff inserts it. No counts are faked and no
// view is laid over the row.
void NBZInstallActionBarHooks(void);

// Asks the live action row to rebuild (used when the Block setting changes).
void NBZRefreshActionBar(void);

NS_ASSUME_NONNULL_END
