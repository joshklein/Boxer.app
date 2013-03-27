/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXDrive.h"
#import "NSWorkspace+ADBMountedVolumes.h"
#import "NSWorkspace+ADBFileTypes.h"
#import "NSString+ADBPaths.h"
#import "RegexKitLite.h"
#import "BXFileTypes.h"
#import "NSURL+ADBFilesystemHelpers.h"
#import "ADBShadowedFilesystem.h"


#pragma mark - Private API declarations

@interface BXDrive ()

@property (readwrite, assign, nonatomic) BXDriveType type;
@property (readwrite, retain, nonatomic) NSMutableSet *pathAliases;
@property (readwrite, retain, nonatomic) id <ADBFilesystemLocalFileURLAccess> filesystem;

@end

#pragma mark - Implementation

@implementation BXDrive
@synthesize path = _path;
@synthesize shadowPath = _shadowPath;
@synthesize mountPoint = _mountPoint;
@synthesize pathAliases = _pathAliases;
@synthesize letter = _letter;
@synthesize title = _title;
@synthesize volumeLabel = _volumeLabel;
@synthesize DOSVolumeLabel = _DOSVolumeLabel;
@synthesize type = _type;
@synthesize freeSpace = _freeSpace;
@synthesize usesCDAudio = _usesCDAudio;
@synthesize readOnly = _readOnly;
@synthesize locked = _locked;
@synthesize hidden = _hidden;
@synthesize mounted = _mounted;
@synthesize filesystem = _filesystem;

#pragma mark - Class methods

+ (NSString *) descriptionForType: (BXDriveType)driveType
{
	static NSArray *descriptions = nil;
	if (!descriptions) descriptions = [[NSArray alloc] initWithObjects:
		NSLocalizedString(@"hard disk",             @"Label for hard disk mounts."),				//BXDriveTypeHardDisk
		NSLocalizedString(@"floppy disk",           @"Label for floppy-disk mounts."),				//BXDriveTypeFloppyDisk
		NSLocalizedString(@"CD-ROM",                @"Label for CD-ROM drive mounts."),				//BXDriveTypeCDROM
		NSLocalizedString(@"internal system disk",	@"Label for DOSBox virtual drives (i.e. Z)."),	//BXDriveTypeInternal
	nil];
	NSAssert1(driveType >= BXDriveHardDisk && (NSUInteger)driveType < descriptions.count,
			  @"Unknown drive type supplied to BXDrive descriptionForType: %i", driveType);
	
	return [descriptions objectAtIndex: driveType];
}

+ (BXDriveType) preferredTypeForPath: (NSString *)filePath
{	
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	if ([workspace file: filePath matchesTypes: [BXFileTypes cdVolumeTypes]])		return BXDriveCDROM;
	if ([workspace file: filePath matchesTypes: [BXFileTypes floppyVolumeTypes]])	return BXDriveFloppyDisk;

	//Check the volume type of the underlying filesystem for that path
	NSString *volumeType = [workspace volumeTypeForPath: filePath];
	
	//Mount data or audio CD volumes as CD-ROM drives 
	if ([volumeType isEqualToString: ADBDataCDVolumeType] || [volumeType isEqualToString: ADBAudioCDVolumeType])
		return BXDriveCDROM;

	//If the path is a FAT/FAT32 volume, check its volume size:
	//volumes smaller than BXFloppySizeCutoff will be treated as floppy disks.
	if ([workspace isFloppyVolumeAtPath: filePath]) return BXDriveFloppyDisk;
	
	//Fall back on a standard hard-disk mount
	return BXDriveHardDisk;
}

+ (NSString *) preferredTitleForPath: (NSString *)filePath
{
    NSString *label = [self preferredVolumeLabelForPath: filePath];
    if (label.length > 1) return label;
	else return [[NSFileManager defaultManager] displayNameAtPath: filePath];
}

+ (NSSet *) mountableTypesWithExtensions
{
	static NSMutableSet *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = [[BXFileTypes mountableImageTypes] mutableCopy];
        [types unionSet: [BXFileTypes mountableFolderTypes]];
        [types addObject: BXGameboxType];
    });
	return types;
}

+ (NSString *) preferredVolumeLabelForPath: (NSString *)filePath
{
    //Dots in DOS volume labels are acceptable, but may be confused with file extensions which
    //we do want to remove. So, we strip off the extensions for our known image/folder types.
    BOOL stripExtension = [[NSWorkspace sharedWorkspace] file: filePath matchesTypes: [self mountableTypesWithExtensions]];
    
    NSString *baseName = filePath.lastPathComponent;
    if (stripExtension)
        baseName = baseName.stringByDeletingPathExtension;
	
    //Imported drives may have an increment on the end to avoid filename collisions, so parse that off too.
    NSString *incrementSuffix = [baseName stringByMatching: @" (\\(\\d+\\))$"];
    if (incrementSuffix)
        baseName = [baseName substringToIndex: baseName.length - incrementSuffix.length];
    
	//Bundled drives can include a letter prefix preceding the label with a space,
    //so if there's both then parse out the letter prefix.
    //(If the name is only a single letter without anything following it, then we treat that
    //letter as the label, to avoid false negatives for single-letter game titles like "Z".)
    NSString *letterPrefix = [baseName stringByMatching: @"^([a-xA-X] )?(.+)$" capture: 1];
    if (letterPrefix)
        baseName = [baseName substringFromIndex: letterPrefix.length];
    
    //TODO: should we trim leading and trailing whitespace? Are spaces meaningful DOS volume labels?
    
	return baseName;
}

+ (NSString *) preferredDriveLetterForPath: (NSString *)filePath
{
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	if ([workspace file: filePath matchesTypes: [BXFileTypes mountableImageTypes]] ||
		[workspace file: filePath matchesTypes: [BXFileTypes mountableFolderTypes]])
	{
		NSString *baseName			= filePath.stringByDeletingPathExtension.lastPathComponent;
		NSString *detectedLetter	= [baseName stringByMatching: @"^([a-xA-X])( .*)?$" capture: 1];
		return detectedLetter;	//will be nil if no match was found
	}
	return nil;
}

+ (NSString *) mountPointForPath: (NSString *)filePath
{
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	if ([workspace file: filePath matchesTypes: [NSSet setWithObject: @"net.washboardabs.boxer-cdrom-bundle"]])
	{
		return [filePath stringByAppendingPathComponent: @"tracks.cue"];
	}
	else return filePath;
}

//Pretty much all our properties depend on our path, so we add it here
+ (NSSet *)keyPathsForValuesAffectingValueForKey: (NSString *)key
{
	NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey: key];
	if (![key isEqualToString: @"path"]) keyPaths = [keyPaths setByAddingObject: @"path"];
	return keyPaths;
}


#pragma mark -
#pragma mark Initializers

- (id) init
{
	if ((self = [super init]))
	{
		//Initialise properties to sensible defaults
        self.type = BXDriveHardDisk;
        self.freeSpace = BXDefaultFreeSpace;
        self.usesCDAudio = YES;
        
        self.pathAliases = [NSMutableSet setWithCapacity: 1];
	}
	return self;
}

- (id) initFromPath: (NSString *)drivePath atLetter: (NSString *)driveLetter withType: (BXDriveType)driveType
{
    NSAssert1(!(drivePath == nil && driveType != BXDriveInternal), @"Nil drive path passed to BXDrive -initFromPath:atLetter:withType:. Drive type was %i, which is not permitted to have an empty drive path.", driveType);
    
	if ((self = [self init]))
	{
		if (driveLetter)
            self.letter = driveLetter;
        
		if (drivePath)
            self.path = drivePath;
        
		//Detect the appropriate mount type for the specified path
		if (driveType == BXDriveAutodetect)
        {
            self.type = [self.class preferredTypeForPath: self.path];
            _hasAutodetectedType = YES;
		}
		else self.type = driveType;
	}
	return self;
}

+ (id) driveFromPath: (NSString *)drivePath atLetter: (NSString *)driveLetter withType: (BXDriveType)driveType
{
	return [[[self alloc] initFromPath: drivePath atLetter: driveLetter withType: driveType] autorelease];
}

+ (id) driveFromPath: (NSString *)drivePath atLetter: (NSString *)driveLetter
{
	return [self driveFromPath: drivePath atLetter: driveLetter withType: BXDriveAutodetect];
}

+ (id) CDROMFromPath: (NSString *)drivePath atLetter: (NSString *)driveLetter
{ return [self driveFromPath: drivePath atLetter: driveLetter withType: BXDriveCDROM]; }
+ (id) floppyDriveFromPath: (NSString *)drivePath atLetter: (NSString *)driveLetter
{ return [self driveFromPath: drivePath atLetter: driveLetter withType: BXDriveFloppyDisk]; }
+ (id) hardDriveFromPath: (NSString *)drivePath atLetter: (NSString *)driveLetter
{ return [self driveFromPath: drivePath atLetter: driveLetter withType: BXDriveHardDisk]; }
+ (id) internalDriveAtLetter: (NSString *)driveLetter
{ return [self driveFromPath: nil atLetter: driveLetter withType: BXDriveInternal]; }

- (void) dealloc
{
    self.path = nil;
    self.shadowPath = nil;
    self.mountPoint = nil;
    self.letter = nil;
    self.title = nil;
    self.volumeLabel = nil;
    self.DOSVolumeLabel = nil;
    self.pathAliases = nil;
    self.filesystem = nil;
    
	[super dealloc];
}


- (void) setPath: (NSString *)filePath
{
	filePath = [filePath stringByStandardizingPath];
	
	if (![self.path isEqualToString: filePath])
	{
		[_path release];
		_path = [filePath copy];
		
		if (filePath)
		{
			if (!self.mountPoint)
            {
				self.mountPoint = [self.class mountPointForPath: filePath];
                _hasAutodetectedMountPoint = YES;
            }
			
			//Automatically parse the drive letter, title and volume label from the name of the drive
			if (!self.letter)
            {
                self.letter = [self.class preferredDriveLetterForPath: filePath];
                _hasAutodetectedLetter = YES;
            }
            
			if (!self.volumeLabel)
            {
                self.volumeLabel = [self.class preferredVolumeLabelForPath: filePath];
                _hasAutodetectedVolumeLabel = YES;
            }
            
			if (!self.title)
            {
                self.title = [self.class preferredTitleForPath: filePath];
                _hasAutodetectedTitle = YES;
            }
		}
	}
}

- (void) setLetter: (NSString *)driveLetter
{
	driveLetter = driveLetter.uppercaseString;
	
	if (![self.letter isEqualToString: driveLetter])
	{
		[_letter release];
		_letter = [driveLetter copy];
        
        _hasAutodetectedLetter = NO;
	}
}

- (void) setVolumeLabel: (NSString *)newLabel
{
	if (![_volumeLabel isEqualToString: newLabel])
	{
		[_volumeLabel release];
		_volumeLabel = [newLabel copy];
		
        _hasAutodetectedVolumeLabel = NO;
	}
}

- (void) setTitle: (NSString *)title
{
    if (![_title isEqualToString: title])
	{
		[_title release];
		_title = [title copy];
		
        _hasAutodetectedTitle = NO;
	}
}

- (void) setMountPoint: (NSString *)path
{
    if (![_mountPoint isEqualToString: path])
	{
		[_mountPoint release];
		_mountPoint = [path copy];
		
        _hasAutodetectedMountPoint = NO;
        
        //Clear our old filesystem: it will be recreated as needed.
        self.filesystem = nil;
	}
}

- (void) setShadowPath: (NSString *)path
{
    if (![_shadowPath isEqualToString: path])
	{
		[_shadowPath release];
		_shadowPath = [path copy];
        
        //Clear our old filesystem, if it was shadowed.
        if (self.shadowPath && [_filesystem isKindOfClass: [ADBShadowedFilesystem class]])
        {
            self.filesystem = nil;
        }
	}
}

- (id <ADBFilesystemPathAccess>) filesystem
{
    if (!_filesystem && self.mountPoint)
    {
        NSURL *baseURL = [NSURL fileURLWithPath: self.mountPoint];
        
        //TODO: support filesystem shadowing for image-based filesystems
        if (self.shadowPath)
        {
            NSURL *shadowURL = [NSURL fileURLWithPath: self.shadowPath];
            self.filesystem = [ADBShadowedFilesystem filesystemWithBaseURL: baseURL
                                                                 shadowURL: shadowURL];
        }
        else
        {
            self.filesystem = [BXFileTypes filesystemWithContentsOfURL: baseURL error: NULL];
        }
        
        NSAssert1(self.filesystem != nil, @"No suitable filesystem could be found for mount point %@", self.mountPoint);
    }
    return [[_filesystem retain] autorelease];
}

#pragma mark -
#pragma mark Introspecting file paths

- (BOOL) representsPath: (NSString *)basePath
{
	if (self.isInternal) return NO;
	basePath = [basePath stringByStandardizingPath];
	
	if ([self.path isEqualToString: basePath]) return YES;
	if ([self.mountPoint isEqualToString: basePath]) return YES;
	if ([self.pathAliases containsObject: basePath]) return YES;
	
	return NO;
}

- (BOOL) exposesPath: (NSString *)subPath
{
	if (self.isInternal) return NO;
	subPath = [subPath stringByStandardizingPath];
	
	if ([subPath isEqualToString: self.path]) return YES;
	if ([subPath isRootedInPath: self.mountPoint]) return YES;
	
	for (NSString *alias in self.pathAliases)
	{
		if ([subPath isRootedInPath: alias]) return YES;
	}
	
	return NO;
}

- (NSString *) relativeLocationOfPath: (NSString *)realPath
{
	if (self.isInternal) return nil;
	realPath = [realPath stringByStandardizingPath];
	
	NSString *relativePath = nil;
	
	//Special-case: map the 'represented' path directly onto the mount path
	if ([realPath isEqualToString: self.path])
	{
		relativePath = @"";
	}
	
	else if ([realPath isRootedInPath: self.mountPoint])
	{
		relativePath = [realPath substringFromIndex: self.mountPoint.length];
	}
	
	else
	{
		for (NSString *alias in self.pathAliases)
		{
			if ([realPath isRootedInPath: alias])
			{
				relativePath = [realPath substringFromIndex: alias.length];
				break;
			}
		}
	}
	
	//Strip any leading slash from the relative path
	if (relativePath && [relativePath hasPrefix: @"/"])
		relativePath = [relativePath substringFromIndex: 1];
	
	return relativePath;
}

- (BOOL) isInternal	{ return (self.type == BXDriveInternal); }
- (BOOL) isCDROM	{ return (self.type == BXDriveCDROM); }
- (BOOL) isFloppy	{ return (self.type == BXDriveFloppyDisk); }
- (BOOL) isHardDisk	{ return (self.type == BXDriveHardDisk); }
- (BOOL) isReadOnly { return _readOnly || self.isCDROM || self.isInternal; }

- (NSString *) typeDescription
{
	return [self.class descriptionForType: self.type];
}
- (NSString *) description
{
	return [NSString stringWithFormat: @"%@: %@ (%@)", self.letter, self.path, self.typeDescription]; 
}

- (NSString *) displayName
{
	if      (self.title) return self.title;
	else if (self.volumeLabel) return self.volumeLabel;
	else if (self.path)
	{
		NSFileManager *manager = [NSFileManager defaultManager];
		return [manager displayNameAtPath: self.path];
	}
	else
	{
		return self.typeDescription;
	}
}


#pragma mark -
#pragma mark Drive sort comparisons

//Sort by path depth
- (NSComparisonResult) pathDepthCompare: (BXDrive *)comparison
{
	return [self.path pathDepthCompare: comparison.path];
}

//Sort by drive letter
- (NSComparisonResult) letterCompare: (BXDrive *)comparison
{
	return [self.letter caseInsensitiveCompare: comparison.letter];
}

@end