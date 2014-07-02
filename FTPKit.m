//
//  FTPKit.m
//  FTPClass
//
//  Created by Cody Sorgenfrey on 6/9/14.
//  Copyright (c) 2014 South Hill Calvary Chapel. All rights reserved.
//

#import "FTPKit.h"
#import <CFNetwork/CFNetwork.h>

enum {
    kSendBufferSize = 32768
};

@interface FTPKit () <NSStreamDelegate>

#pragma mark Directory Listing Properties

@property NSInputStream  *directoryListingStream;
@property NSMutableArray *directoryListingResults;
@property SEL            directoryDidFinishListingSelector;
@property NSMutableData  *directoryListingRawData;

#pragma mark New Directory Properties

@property NSOutputStream  *makeNewDirectoryStream;
@property SEL             makeNewDirectoryDidFinishSelector;

#pragma mark Upload File Properties

@property                                NSInputStream      *uploadFileLocalStream;
@property                                NSOutputStream     *uploadFileNetworkStream;
@property                                SEL                uploadFileDidWriteBytesSelector;
@property                                SEL                uploadFileDidCompleteSelector;
@property (nonatomic, assign, readonly)  uint8_t            *uploadFileBuffer;
@property                                size_t             uploadFileBufferOffset;
@property                                size_t             uploadFileBufferLimit;
@property                                unsigned long long uploadFileFileSize;
@property                                NSInteger          uploadFileTotalBytesWritten;

#pragma mark Download File Properties

@property                                NSOutputStream     *downloadFileLocalStream;
@property                                NSInputStream      *downloadFileNetworkStream;
@property                                SEL                downloadFileDidWriteBytesSelector;
@property                                SEL                downloadFileDidCompleteSelector;
@property                                NSInteger          downloadFileFileSize;
@property                                NSInteger          downloadFileTotalBytesWritten;


-(void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode;

@end

@implementation FTPKit
{
    uint8_t                     _uploadFileBuffer[kSendBufferSize];
}

#pragma mark Shared Methods

-(id)init
{
    if (self = [super init]) {
        self.directoryListingRawData = [NSMutableData data];
        self.directoryListingResults = [NSMutableArray array];
    }
    return self;
}

-(void)showError:(id)error
{
    if ([error isKindOfClass:[NSString class]]) {
        NSDictionary *dic = [NSDictionary dictionaryWithObject:error forKey:NSLocalizedDescriptionKey];
        error = [NSError errorWithDomain:@"ftpKitErrorDomain" code:200 userInfo:dic];
    } else if ([error isKindOfClass:[NSError class]]){
        ;//do nothing
    } else {
        NSLog(@"Error: %@", error);
    }
    
    if ([self.delegate respondsToSelector:self.errorMethod]) {
        [self.delegate performSelector:self.errorMethod withObject:error];
    } else {
        NSLog(@"Error: %@", error);
    }
}

-(NSURL *)ftpURLForString:(NSString *)str isDirectory:(BOOL)isDir
{
    NSURL *result;
    
    NSString *trimmedStr = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ( (trimmedStr != nil) && ([trimmedStr length] != 0) ) {
        NSRange schemeMarkerRange = [trimmedStr rangeOfString:@"://"];
        
        if (schemeMarkerRange.location == NSNotFound) {
            result = [NSURL URLWithString:[NSString stringWithFormat:@"ftp://%@", trimmedStr]];
        } else {
            NSString *scheme = [trimmedStr substringWithRange:NSMakeRange(0, schemeMarkerRange.location)];
            
            if ( ([scheme compare:@"ftp"  options:NSCaseInsensitiveSearch] == NSOrderedSame) ) {
                result = [NSURL URLWithString:trimmedStr];
            }
        }
        if (isDir) {
            unichar lastChar = [[result absoluteString] characterAtIndex: ([[result absoluteString] length] -1)];
            if (lastChar != [@"/" characterAtIndex:0]) {
                result = [result URLByAppendingPathComponent:@"/"];
            }
        }
    }
    
    return result;
}

-(NSString *)localURLForString:(NSString *)str isDirectory:(BOOL)isDir
{
    NSString *result;
    
    if ([[str substringToIndex:7] isEqualToString:@"file://"]) {
        result = [str substringFromIndex:7];
    } else {
        result = str;
    }
    if (isDir) {
        if ([[result substringFromIndex:([result length] - 2)] isNotEqualTo:@"/"]) {
            result = [result stringByAppendingString:@"/"];
        }
    }
    
    return result;
}

-(void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
    if ([aStream isEqualTo:self.directoryListingStream]) {
        switch (eventCode) {
            case NSStreamEventHasBytesAvailable: {
                NSInteger       bytesToRead;
                uint8_t         buffer[32768];
                
                // Pull some data off the network.
                bytesToRead = [self.directoryListingStream read:buffer maxLength:sizeof(buffer)];
                if (bytesToRead < 0) {
                    [self showError:@"Network read error"];
                    [self resetForDirectoryListing];
                } else if (bytesToRead == 0) {
                    //Done.
                    if (!self.directoryListingShowHiddenFiles) {
                        [self hideHiddenFiles: self.directoryListingResults];
                    }
                    if ([self.delegate respondsToSelector: self.directoryDidFinishListingSelector]){
                        [self.delegate performSelector: self.directoryDidFinishListingSelector withObject: [self.directoryListingResults copy]];
                    }
                    [self resetForDirectoryListing];
                } else {
                    // Append the data to our listing buffer.
                    [self.directoryListingRawData appendBytes:buffer length:(NSUInteger) bytesToRead];
                    
                    // Check the listing buffer for any complete entries
                    [self.directoryListingResults addObjectsFromArray: [self directoryListingParseRawData: self.directoryListingRawData]];
                }
            } break;
            case NSStreamEventErrorOccurred: {
                [self showError:[self.directoryListingStream streamError]];
                [self resetForDirectoryListing];
            } break;
        }
    } else if ([aStream isEqualTo:self.makeNewDirectoryStream]) {
        switch (eventCode) {
            case NSStreamEventEndEncountered: {
                //Done.
                if ([self.delegate respondsToSelector: self.makeNewDirectoryDidFinishSelector]){
                    [self.delegate performSelector: self.makeNewDirectoryDidFinishSelector];
                }
                [self resetForMakeNewDirectory];
            } break;
            case NSStreamEventErrorOccurred: {
                [self showError:[self.makeNewDirectoryStream streamError]];
                [self resetForMakeNewDirectory];
            } break;
        }
    } else if ([aStream isEqualTo:self.uploadFileNetworkStream]) {
        switch (eventCode) {
            case NSStreamEventHasSpaceAvailable: {
                // If we don't have any data buffered, go read the next chunk of data.
                if (self.uploadFileBufferOffset == self.uploadFileBufferLimit) {
                    NSInteger   bytesRead;
                    
                    bytesRead = [self.uploadFileLocalStream read:self.uploadFileBuffer maxLength:kSendBufferSize];
                    
                    if (bytesRead == -1) {
                        [self showError:@"Local stream read error."];
                        [self resetForUploadFile];
                    } else if (bytesRead == 0) {
                        if ([self.delegate respondsToSelector:self.uploadFileDidCompleteSelector]) {
                            [self.delegate performSelector: self.uploadFileDidCompleteSelector];
                        }
                        [self resetForUploadFile];
                    } else {
                        self.uploadFileBufferOffset = 0;
                        self.uploadFileBufferLimit  = bytesRead;
                    }
                }
                // If we're not out of data completely, send the next chunk.
                if (self.uploadFileBufferOffset != self.uploadFileBufferLimit) {
                    NSInteger   bytesWritten;
                    bytesWritten = [self.uploadFileNetworkStream write:&self.uploadFileBuffer[self.uploadFileBufferOffset] maxLength:self.uploadFileBufferLimit - self.uploadFileBufferOffset];
                    assert(bytesWritten != 0);
                    if (bytesWritten == -1) {
                        [self showError:@"Network stream write error."];
                        [self resetForUploadFile];
                    } else {
                        self.uploadFileBufferOffset += bytesWritten;
                        self.uploadFileTotalBytesWritten += bytesWritten;
                    }
                }
                if ([self.delegate respondsToSelector: self.uploadFileDidWriteBytesSelector]) {
                    NSNumber *fileSize = [NSNumber numberWithUnsignedLongLong: self.uploadFileFileSize];
                    NSNumber *fileOffset = [NSNumber numberWithInteger: self.uploadFileTotalBytesWritten];
                    [self.delegate performSelector: self.uploadFileDidWriteBytesSelector withObject: [fileOffset copy] withObject: [fileSize copy]];
                }
            } break;
            case NSStreamEventErrorOccurred: {
                [self showError:[self.uploadFileNetworkStream streamError]];
                [self resetForUploadFile];
            } break;
        }
    } else if ([aStream isEqualTo:self.downloadFileNetworkStream]) {
        switch (eventCode) {
            case NSStreamEventHasBytesAvailable: {
                NSInteger       bytesRead;
                uint8_t         buffer[32768];
                
                bytesRead = [self.downloadFileNetworkStream read:buffer maxLength:sizeof(buffer)];
                if (bytesRead == -1) {
                    [self showError:@"Network stream read error"];
                    [self resetForDownloadFile];
                } else if (bytesRead == 0) {
                    if ([self.delegate respondsToSelector: self.downloadFileDidCompleteSelector]) {
                        [self.delegate performSelector: self.downloadFileDidCompleteSelector];
                    }
                    [self resetForDownloadFile];
                } else {
                    NSInteger   bytesWritten;
                    NSInteger   bytesWrittenSoFar;
                    
                    // Write to the file.
                    
                    bytesWrittenSoFar = 0;
                    do {
                        bytesWritten = [self.downloadFileLocalStream write:&buffer[bytesWrittenSoFar] maxLength:(NSUInteger) (bytesRead - bytesWrittenSoFar)];
                        assert(bytesWritten != 0);
                        if (bytesWritten == -1) {
                            [self showError:@"File write error"];
                            [self resetForDownloadFile];
                            break;
                        } else {
                            bytesWrittenSoFar += bytesWritten;
                            self.downloadFileTotalBytesWritten += bytesWritten;
                        }
                    } while (bytesWrittenSoFar != bytesRead);
                    
                    if ([self.delegate respondsToSelector:self.downloadFileDidWriteBytesSelector]) {
                        NSNumber *totalBytes = [NSNumber numberWithInteger: self.downloadFileFileSize];
                        NSNumber *bytesWritten = [NSNumber numberWithInteger: self.downloadFileTotalBytesWritten];
                        [self.delegate performSelector:self.downloadFileDidWriteBytesSelector withObject:bytesWritten withObject:totalBytes];
                    }
                }
            } break;
            case NSStreamEventErrorOccurred: {
                [self showError:[self.downloadFileNetworkStream streamError]];
                [self resetForDownloadFile];
            } break;
        }
    }
}

-(void)hideHiddenFiles:(NSMutableArray *)directoryListing
{
    NSMutableArray *objectsToRemove = [NSMutableArray array];
    for (NSDictionary *entry in directoryListing) {
        if ([[entry objectForKey:kCFFTPResourceName] hasPrefix:@"."] || [[entry objectForKey:kCFFTPResourceName] hasPrefix:@","]) {
            [objectsToRemove addObject:entry];
        }
    }
    [directoryListing removeObjectsInArray:objectsToRemove];
}

#pragma mark Directory Listing Methods

-(void)resetForDirectoryListing
{
    [self.directoryListingStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.directoryListingStream close];
    self.directoryListingStream = nil;
    self.directoryListingRawData = [NSMutableData data];
    [self.directoryListingResults removeAllObjects];
}

-(BOOL)getDirectoryListingForPath:(NSString *)path onComplete:(SEL)method
{
    self.directoryDidFinishListingSelector = method;
    
    NSURL *url = [self ftpURLForString: [self.serverAddress stringByAppendingString: path] isDirectory:true];
    
    self.directoryListingStream = (NSInputStream *)CFBridgingRelease(
        CFReadStreamCreateWithFTPURL(NULL, (__bridge CFURLRef) url)
    );
    
    self.directoryListingStream.delegate = (id)self;
    if (self.userName && self.password) {
        [self.directoryListingStream setProperty:self.userName forKey: (id)kCFStreamPropertyFTPUserName];
        [self.directoryListingStream setProperty:self.password forKey: (id)kCFStreamPropertyFTPPassword];
    }
    [self.directoryListingStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.directoryListingStream open];
    
    if ([self.directoryListingStream streamStatus] != kCFStreamStatusError) {
        return true;
    } else{
        return false;
    }
}

-(NSArray *)getDirectoryListingForPathSync:(NSString *)path
{
    NSInputStream  *myStream;
    NSMutableData  *rawData = [NSMutableData data];
    NSMutableArray *directoryListing = [NSMutableArray array];
    BOOL           runnning = true;
    
    NSURL *url = [self ftpURLForString: [self.serverAddress stringByAppendingString: path] isDirectory:true];
    
    myStream = (NSInputStream *)CFBridgingRelease(
                                                  CFReadStreamCreateWithFTPURL(NULL, (__bridge CFURLRef) url)
                                                  );
    
    if (self.userName && self.password) {
        [myStream setProperty:self.userName forKey: (id)kCFStreamPropertyFTPUserName];
        [myStream setProperty:self.password forKey: (id)kCFStreamPropertyFTPPassword];
    }
    [myStream open];
    
    do {
        switch ([myStream streamStatus]) {
            case NSStreamStatusError: {
                [self showError: [myStream streamError]];
                runnning = false;
            } break;
            case NSStreamStatusOpen: {
                if ([myStream hasBytesAvailable]) {
                    NSInteger       bytesToRead;
                    uint8_t         buffer[32768];
                    
                    bytesToRead = [myStream read:buffer maxLength:sizeof(buffer)];
                    if (bytesToRead < 0) {
                        //Couldn't find file/folder
                        [self showError: [myStream streamError]];
                    } else if (bytesToRead == 0) {
                        //Done
                        runnning = false;
                    } else {
                        [rawData appendBytes:buffer length:(NSUInteger) bytesToRead];
                        [directoryListing addObjectsFromArray: [self directoryListingParseRawData:rawData]];
                    }
                }
            } break;
        }
    } while (runnning);
    
    [myStream close];
    return [directoryListing copy];
}

- (NSArray *)directoryListingParseRawData: (NSMutableData *)data
{
    NSMutableArray *    newEntries = [NSMutableArray array];
    NSUInteger          offset     = 0;
    
    do {
        CFIndex         bytesConsumed;
        CFDictionaryRef thisEntry = NULL;
        
        
        assert(offset <= [data length]);
        bytesConsumed = CFFTPCreateParsedResourceListing(NULL, &((const uint8_t *) data.bytes)[offset], (CFIndex) ([data length] - offset), &thisEntry);
        if (bytesConsumed > 0) {
            if (thisEntry != NULL) {
                NSDictionary *entryToAdd = [self fixEntryEncoding:(__bridge NSDictionary *) thisEntry encoding:NSUTF8StringEncoding];
                [newEntries addObject:entryToAdd];
            }
            offset += (NSUInteger) bytesConsumed;
        }
        if (thisEntry != NULL) {
            CFRelease(thisEntry);
        }
        if (bytesConsumed == 0) {
            break;
        } else if (bytesConsumed < 0) {
            [self showError:@"Listing parse failed"];
            [self resetForDirectoryListing];
            break;
        }
    } while (YES);
    
//    if ([newEntries count] != 0) {
//        if (self.directoryListingShowHiddenFiles) {
//            [self.directoryListingResults addObjectsFromArray:newEntries];
//        } else {
//            for (NSDictionary *dic in newEntries) {
//                unichar myChar = [[dic objectForKey:(id)kCFFTPResourceName] characterAtIndex:0];
//                if (myChar != [@"." characterAtIndex:0] && myChar != [@"," characterAtIndex:0]) {
//                    [self.directoryListingResults addObject:dic];
//                }
//            }
//        }
//    }
    if (offset != 0) {
        [data replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    }
    return [newEntries copy];
}

- (NSDictionary *)fixEntryEncoding:(NSDictionary *)entry encoding:(NSStringEncoding)newEncoding
{
    NSDictionary *  result;
    NSData *        nameData;
    NSString *      newName = nil;;
    
    NSString *name = [entry objectForKey:(id) kCFFTPResourceName];
    if (name != nil) {
        assert([name isKindOfClass:[NSString class]]);
        
        nameData = [name dataUsingEncoding:NSMacOSRomanStringEncoding];
        if (nameData != nil) {
            newName = [[NSString alloc] initWithData:nameData encoding:newEncoding];
        }
    }
    
    if (newName == nil) {
        result = (NSDictionary *) entry;
        [self showError:@"Server encoding error"];
    } else {
        NSMutableDictionary *   newEntry;
        
        newEntry = [entry mutableCopy];
        [newEntry setObject:newName forKey:(id) kCFFTPResourceName];
        
        result = newEntry;
    }
    
    return result;
}

#pragma mark New Directory Methods

-(BOOL)makeNewDirectoryAtPath:(NSString *)path onComplete:(SEL)method
{
    self.makeNewDirectoryDidFinishSelector = method;
    
    NSURL *url = [self ftpURLForString:[self.serverAddress stringByAppendingString:path] isDirectory:true];
    
    self.makeNewDirectoryStream = CFBridgingRelease(
        CFWriteStreamCreateWithFTPURL(kCFAllocatorDefault, (__bridge CFURLRef)url)
    );
    
    [self.makeNewDirectoryStream setDelegate:(id)self];
    if (self.userName && self.password) {
        [self.makeNewDirectoryStream setProperty:self.userName forKey:(id)kCFStreamPropertyFTPUserName];
        [self.makeNewDirectoryStream setProperty:self.password forKey:(id)kCFStreamPropertyFTPPassword];
    }
    [self.makeNewDirectoryStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.makeNewDirectoryStream open];
    
    if ([self.makeNewDirectoryStream streamStatus] != kCFStreamStatusError) {
        return true;
    } else{
        return false;
    }
}

-(void)resetForMakeNewDirectory
{
    [self.makeNewDirectoryStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.makeNewDirectoryStream close];
    self.makeNewDirectoryStream = nil;
}

#pragma mark Upload File Methods

-(uint8_t *)uploadFileBuffer
{
    return self->_uploadFileBuffer;
}

-(BOOL)uploadFile:(NSString *)pathToFile toServerPath:(NSString *)pathOnServer onUpdate:(SEL)updateMethod onComplete:(SEL)completeMethod
{
    self.uploadFileDidWriteBytesSelector = updateMethod;
    self.uploadFileDidCompleteSelector = completeMethod;
    
    NSURL *url = [self ftpURLForString:[self.serverAddress stringByAppendingString:pathOnServer] isDirectory:true];
    url = [url URLByAppendingPathComponent: [pathToFile lastPathComponent]];
    
    pathToFile = [self localURLForString:pathToFile isDirectory:false];
    NSDictionary *fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:pathToFile error:nil];
    self.uploadFileFileSize = [fileInfo fileSize];
    
    self.uploadFileLocalStream = [NSInputStream inputStreamWithFileAtPath: pathToFile];
    [self.uploadFileLocalStream open];
    
    self.uploadFileNetworkStream = CFBridgingRelease(
        CFWriteStreamCreateWithFTPURL(NULL, (__bridge CFURLRef) url)
    );
    
    if (self.userName && self.password) {
        [self.uploadFileNetworkStream setProperty:self.userName forKey:(id)kCFStreamPropertyFTPUserName];
        [self.uploadFileNetworkStream setProperty:self.password forKey:(id)kCFStreamPropertyFTPPassword];
    }
    
    self.uploadFileNetworkStream.delegate = self;
    [self.uploadFileNetworkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.uploadFileNetworkStream open];
    
    if ([self.uploadFileNetworkStream streamStatus] != kCFStreamStatusError) {
        return true;
    } else{
        return false;
    }
}

-(void)resetForUploadFile
{
    [self.uploadFileNetworkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.uploadFileNetworkStream close];
    [self.uploadFileLocalStream close];
    self.uploadFileNetworkStream = nil;
    self.uploadFileLocalStream = nil;
    self.uploadFileFileSize = 0;
    self.uploadFileTotalBytesWritten = 0;
}

#pragma mark Download File Methods

-(BOOL)downloadFile:(NSString *)pathOnServer size:(NSInteger)size toPath:(NSString *)localPath onUpdate:(SEL)updateMethod onComplete:(SEL)completeMethod
{
    self.downloadFileDidCompleteSelector = completeMethod;
    self.downloadFileDidWriteBytesSelector = updateMethod;
    
    pathOnServer = [self.serverAddress stringByAppendingPathComponent:pathOnServer];
    NSURL *url = [self ftpURLForString:pathOnServer isDirectory:false];
    localPath = [self localURLForString:localPath isDirectory:true];
    
    localPath = [localPath stringByAppendingString: [url lastPathComponent]];
    
    self.downloadFileFileSize = size; 
    
    self.downloadFileLocalStream = [NSOutputStream outputStreamToFileAtPath:localPath append:false];
    [self.downloadFileLocalStream open];
    
    self.downloadFileNetworkStream = CFBridgingRelease(
        CFReadStreamCreateWithFTPURL(NULL, (__bridge CFURLRef) url)
    );
    
    [self.downloadFileNetworkStream setDelegate:(id)self];
    if (self.userName && self.password) {
        [self.downloadFileNetworkStream setProperty:self.userName forKey:(id)kCFStreamPropertyFTPUserName];
        [self.downloadFileNetworkStream setProperty:self.password forKey:(id)kCFStreamPropertyFTPPassword];
    }
    [self.downloadFileNetworkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.downloadFileNetworkStream open];
    
    if ([self.downloadFileNetworkStream streamStatus] != kCFStreamStatusError) {
        return true;
    } else{
        return false;
    }
}

-(void)resetForDownloadFile
{
    [self.downloadFileNetworkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.downloadFileNetworkStream close];
    [self.downloadFileLocalStream close];
    self.downloadFileNetworkStream = nil;
    self.downloadFileLocalStream = nil;
}











@end
