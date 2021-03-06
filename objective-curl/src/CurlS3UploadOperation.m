//
//  S3UploadOperation.m
//  objective-curl
//
//  Copyright 2010 Nick Jensen <http://goto11.net>
//

#import "NSString+S3.h"
#import "NSString+PathExtras.h"
#import "NSString+URLEncoding.h"
#import "NSFileManager+MimeType.h"
#import "NSObject+DDExtensions.h"

#import "CurlS3UploadOperation.h"
#import "CurlUpload.h"
#import "CurlUploadDelegate.h"
#import "CurlFileTransfer.h"
#import "CurlS3ErrorParser.h"
#import "CurlS3DateUtil.h"

@implementation CurlS3UploadOperation


@synthesize errorCode;

@synthesize errorMessage;



/*
 * If we got a response body from PUT request then we handle it as an error and bail.
 */
static size_t writeFunction(void *ptr, size_t size, size_t nmemb, CurlS3UploadOperation *op)
{			
	NSString *resp = [NSString stringWithUTF8String:(char *)ptr];
	
	NSDictionary *err = [CurlS3ErrorParser parseErrorDetails:resp];
	
	[op setErrorCode:[err objectForKey:S3ErrorCodeKey]];
	[op setErrorMessage:[err objectForKey:S3ErrorMessageKey]];
	
    return 0;
}


/*
 * Set curl options for Amazon S3.
 */ 
- (void)setProtocolSpecificOptions
{
	curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 0);
	curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, writeFunction);
	curl_easy_setopt(handle, CURLOPT_WRITEDATA, self);
	curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1);
	curl_easy_setopt(handle, CURLOPT_MAXREDIRS, 10);
	curl_easy_setopt(handle, CURLOPT_NETRC, CURL_NETRC_IGNORED);
}


/*
 * Set S3 Auth/HTTP Headers for the current file being uploaded. 
 *
 */
- (void)setFileSpecificOptions:(CurlFileTransfer *)file
{		
	// These act the same as username and password
	NSString *accessKey = [upload username];
	NSString *secretKey = [upload password];

	NSString *date = [CurlS3DateUtil dateStringForNow];
	
	NSString *resource = [[NSString stringWithFormat:@"/%@", [[file remotePath] stringByRemovingTildePrefix]] encodedURLString];
		
	// Get the content type of the file we're uploading
	NSString *contentType = [NSFileManager mimeTypeForFileAtPath:[file localPath]];

	// TODO - don't hardcode this
	NSString *acl = @"x-amz-acl:public-read";
	
	// Details of the request to be signed
	NSString *stringToSign = [NSString stringWithFormat:@"PUT\n\n%@\n%@\n%@\n%@", contentType, date, acl, resource];
	
	// Construct the S3 authorization header
	NSString *authString = [NSString stringWithFormat:@"AWS %@:%@", 
								accessKey, [stringToSign signS3PutRequestWithKey:secretKey]];
	
	struct curl_slist *headers = NULL;
	
	// Set the Request Headers
	headers = curl_slist_append(headers, "User-Agent:");
	headers = curl_slist_append(headers, "Accept:");
	headers = curl_slist_append(headers, "Expect:");
	headers = curl_slist_append(headers, [acl UTF8String]);
	headers = curl_slist_append(headers, [[NSString stringWithFormat:@"Content-Type: %@", contentType] UTF8String]);
	headers = curl_slist_append(headers, [[NSString stringWithFormat:@"Date: %@", date] UTF8String]);
	headers = curl_slist_append(headers, [[NSString stringWithFormat:@"Authorization: %@", authString] UTF8String]);

	curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);

	// TODO - figure out a way to free the headers
}



/*
 * Overridden to handle Amazon S3 Specific Failures. 
 *
 */
- (void)handleUploadFailed:(CURLcode)result
{
	// The upload operation failed.
	int status;
	switch (result)
	{
		// Aborted from the write_func? That means Amazon S3 threw an error...
		case CURLE_WRITE_ERROR:
			status = [CurlS3ErrorParser transferStatusForErrorCode:errorCode];
			break;
			
		// Otherwise, process as a normal error.
		default:
			return [super handleUploadFailed:result];
	}
	
	[upload setStatus:status];

	NSString *message = (status == CURL_TRANSFER_STATUS_LOGIN_DENIED) ?
		[self getFailureDetailsForStatus:CURLE_LOGIN_DENIED withObject:upload] : 
			[NSString stringWithFormat:@"%@:%@", errorCode, errorMessage];
	
	if (delegate && [delegate respondsToSelector:@selector(uploadDidFail:message:)])
	{
		[[delegate invokeOnMainThread] uploadDidFail:upload message:message];
	}
}


- (NSString *)urlForTransfer:(CurlFileTransfer *)file
{
	NSString *filePath = [[file remotePath] stringByRemovingTildePrefix];
	
	NSString *path = [[NSString stringWithFormat:@"%@:%d", [upload hostname], [upload port]] stringByAppendingPathComponent:filePath];
	
	NSString *url = [NSString stringWithFormat:@"%@://%@", [upload protocolPrefix], [path encodedURLString]];
	
	return url;
}


@end
