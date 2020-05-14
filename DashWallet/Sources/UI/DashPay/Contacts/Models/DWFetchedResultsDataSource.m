//
//  Created by administrator
//  Copyright © 2020 Dash Core Group. All rights reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DWFetchedResultsDataSource.h"

#import <DashSync/DSLogger.h>
#import <DashSync/NSPredicate+DSUtils.h>

static NSUInteger const FETCH_BATCH_SIZE = 20;

#pragma mark - Diff

NS_ASSUME_NONNULL_BEGIN

@interface DWFetchedResultsDataSourceDiffUpdate ()

@property (readonly, nonatomic, strong) NSMutableArray<NSIndexPath *> *mutableInserts;
@property (readonly, nonatomic, strong) NSMutableArray<NSIndexPath *> *mutableDeletes;
@property (readonly, nonatomic, strong) NSMutableArray<NSIndexPath *> *mutableUpdates;
@property (readonly, nonatomic, strong) NSMutableArray<NSArray<NSIndexPath *> *> *mutableMoves;

@end

NS_ASSUME_NONNULL_END

@implementation DWFetchedResultsDataSourceDiffUpdate

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _mutableInserts = [NSMutableArray array];
        _mutableDeletes = [NSMutableArray array];
        _mutableUpdates = [NSMutableArray array];
        _mutableMoves = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSIndexPath *> *)inserts {
    return [self.mutableInserts copy];
}

- (NSArray<NSIndexPath *> *)deletes {
    return [self.mutableDeletes copy];
}

- (NSArray<NSIndexPath *> *)updates {
    return [self.mutableUpdates copy];
}

- (NSArray<NSArray<NSIndexPath *> *> *)moves {
    return [self.mutableMoves copy];
}

@end

#pragma mark - DataSource

NS_ASSUME_NONNULL_BEGIN

@interface DWFetchedResultsDataSource ()

@property (nullable, nonatomic, strong) DWFetchedResultsDataSourceDiffUpdate *diffUpdate;

@end

NS_ASSUME_NONNULL_END

@implementation DWFetchedResultsDataSource

- (instancetype)initWithContext:(NSManagedObjectContext *)context
                        entityName:(NSString *)entityName
    shouldSubscribeToNotifications:(BOOL)shouldSubscribeToNotifications {
    self = [super init];
    if (self) {
        _context = context;
        _entityName = entityName;
        _shouldSubscribeToNotifications = shouldSubscribeToNotifications;
    }
    return self;
}

- (void)start {
    NSParameterAssert(self.predicate);
    NSParameterAssert(self.sortDescriptors);
    // invertedPredicate is not mandatory

    if (self.shouldSubscribeToNotifications) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundManagedObjectContextDidSaveNotification:)
                                                     name:NSManagedObjectContextDidSaveNotification
                                                   object:self.context];
    }

    [self fetchedResultsController];
}

- (void)stop {
    self.fetchedResultsController = nil;

    if (self.shouldSubscribeToNotifications) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSManagedObjectContextDidSaveNotification
                                                      object:self.context];
    }
}

#pragma mark - Private

- (NSFetchedResultsController *)fetchedResultsController {
    if (_fetchedResultsController != nil) {
        return _fetchedResultsController;
    }

    NSManagedObjectContext *context = self.context;

    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:self.entityName inManagedObjectContext:context];
    fetchRequest.fetchBatchSize = FETCH_BATCH_SIZE;
    fetchRequest.sortDescriptors = self.sortDescriptors;
    fetchRequest.predicate = self.predicate;

    NSFetchedResultsController *fetchedResultsController =
        [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest
                                            managedObjectContext:context
                                              sectionNameKeyPath:nil
                                                       cacheName:nil];
    _fetchedResultsController = fetchedResultsController;
    fetchedResultsController.delegate = self;
    NSError *error = nil;
    if (![fetchedResultsController performFetch:&error]) {
        // Replace this implementation with code to handle the error appropriately.
        // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
        DSLogError(@"Unresolved error %@, %@", error, [error userInfo]);
        abort();
    }

    return _fetchedResultsController;
}

- (NSPredicate *)classPredicate {
    return [NSPredicate predicateWithFormat:@"self isKindOfClass: %@", NSClassFromString(self.entityName)];
}

- (NSPredicate *)predicateInContext {
    return [self.predicate predicateInContext:self.context];
}

- (NSPredicate *)invertedPredicateInContext {
    return [self.invertedPredicate predicateInContext:self.context];
}

- (NSPredicate *)fullPredicateInContext {
    return [NSCompoundPredicate andPredicateWithSubpredicates:@[ [self classPredicate], [self predicateInContext] ]];
}

- (NSPredicate *)fullInvertedPredicateInContext {
    return [NSCompoundPredicate andPredicateWithSubpredicates:@[ [self classPredicate], [self invertedPredicateInContext] ]];
}

- (void)backgroundManagedObjectContextDidSaveNotification:(NSNotification *)notification {
    BOOL (^objectsHaveChanged)(NSSet *) = ^BOOL(NSSet *objects) {
        NSSet *foundObjects = [objects filteredSetUsingPredicate:[self fullPredicateInContext]];
        if (foundObjects.count) {
            return YES;
        }
        return NO;
    };

    BOOL (^objectsHaveChangedInverted)(NSSet *) = ^BOOL(NSSet *objects) {
        if (!self.invertedPredicate) {
            return NO;
        }
        NSSet *foundObjects = [objects filteredSetUsingPredicate:[self fullInvertedPredicateInContext]];
        if (foundObjects.count) {
            return YES;
        }
        return NO;
    };


    NSSet<NSManagedObject *> *insertedObjects = notification.userInfo[NSInsertedObjectsKey];
    NSSet<NSManagedObject *> *updatedObjects = notification.userInfo[NSUpdatedObjectsKey];
    NSSet<NSManagedObject *> *deletedObjects = notification.userInfo[NSDeletedObjectsKey];
    BOOL inserted = NO;
    BOOL updated = NO;
    BOOL deleted = NO;
    BOOL insertedInverted = NO;
    BOOL deletedInverted = NO;
    if ((inserted = objectsHaveChanged(insertedObjects)) ||
        (updated = objectsHaveChanged(updatedObjects)) ||
        (deleted = objectsHaveChanged(deletedObjects)) ||
        (insertedInverted = objectsHaveChangedInverted(insertedObjects)) ||
        (deletedInverted = objectsHaveChangedInverted(deletedObjects))) {
        if (inserted || updated || deleted) {
            insertedInverted = objectsHaveChangedInverted(insertedObjects);
            deletedInverted = objectsHaveChangedInverted(deletedObjects);
        }
        [self.context mergeChangesFromContextDidSaveNotification:notification];
        if (insertedInverted || deletedInverted) {
            self.fetchedResultsController = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate fetchedResultsDataSourceDidUpdate:self];
            });
        }
    }
}

#pragma mark NSFetchedResultsControllerDelegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    self.diffUpdate = [[DWFetchedResultsDataSourceDiffUpdate alloc] initPrivate];
}

- (void)controller:(NSFetchedResultsController *)controller
    didChangeObject:(id)anObject
        atIndexPath:(nullable NSIndexPath *)indexPath
      forChangeType:(NSFetchedResultsChangeType)type
       newIndexPath:(nullable NSIndexPath *)newIndexPath {
    switch (type) {
        case NSFetchedResultsChangeInsert: {
            [self.diffUpdate.mutableInserts addObject:newIndexPath];
            break;
        }
        case NSFetchedResultsChangeDelete: {
            [self.diffUpdate.mutableDeletes addObject:indexPath];
            break;
        }
        case NSFetchedResultsChangeMove: {
            [self.diffUpdate.mutableMoves addObject:@[ indexPath, newIndexPath ]];
            break;
        }
        case NSFetchedResultsChangeUpdate: {
            [self.diffUpdate.mutableUpdates addObject:indexPath];
            break;
        }
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    NSAssert([NSThread isMainThread], @"Main thread is assumed here");
    [self.delegate fetchedResultsDataSource:self didDiffUpdate:self.diffUpdate];
    self.diffUpdate = nil;
}

@end
