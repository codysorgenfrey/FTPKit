//
//  FTPKit.h
//  FTPClass
//
//  Created by Cody Sorgenfrey on 6/9/14.
//  Copyright (c) 2014 South Hill Calvary Chapel. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface FTPKit : NSObject <NSStreamDelegate>

@property id       delegate;
@property NSString *serverAddress;
@property NSString *userName;
@property NSString *password;
@property SEL      errorMethod;
@property BOOL     directoryListingShowHiddenFiles;

-(NSArray *)getDirectoryListingForPathSync:(NSString *)path;
-(BOOL)getDirectoryListingForPath:(NSString *)path onComplete:(SEL)method;
-(BOOL)makeNewDirectoryAtPath:(NSString *)path onComplete:(SEL)method;
-(BOOL)uploadFile:(NSString *)pathToFile toServerPath:(NSString *)pathOnServer onUpdate:(SEL)updateMethod onComplete:(SEL)completeMethod;
-(BOOL)downloadFile:(NSString *)pathOnServer size:(NSInteger)size toPath:(NSString *)localPath onUpdate:(SEL)updateMethod onComplete:(SEL)completeMethod;

@end
