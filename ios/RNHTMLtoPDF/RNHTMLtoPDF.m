
//  Created by Christopher on 9/3/15.

#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTView.h>
#import <React/UIView+React.h>
#import <React/RCTUtils.h>
#import "RNHTMLtoPDF.h"
#import <PDFKit/PDFKit.h>

#define PDFSize CGSizeMake(612,792)

@implementation UIPrintPageRenderer (PDF)
- (NSData*) printToPDF:(NSInteger**)_numberOfPages
            backgroundColor:(UIColor*)_bgColor
            titleInfo:(NSString *)titleInfo
            headerInfo:(NSString *)headerInfo {
    
    NSInteger titlePageCount = 0;
    if (titleInfo) {
        // Create temporary renderer to calculate title pages
        UIPrintPageRenderer *titleRenderer = [[UIPrintPageRenderer alloc] init];
        NSData *htmlData = [titleInfo dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *options = @{ NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType };
        NSAttributedString *attributedString = [[NSAttributedString alloc] initWithData:htmlData
                                                                              options:options
                                                                   documentAttributes:nil
                                                                              error:nil];
        CGRect bounds = self.paperRect;
        titlePageCount = ceil(attributedString.size.height / bounds.size.height);
    }

    NSMutableData *pdfData = [NSMutableData data];
    UIGraphicsBeginPDFContextToData(pdfData, self.paperRect, nil);

    [self prepareForDrawingPages: NSMakeRange(0, self.numberOfPages)];

    CGRect bounds = UIGraphicsGetPDFContextBounds();

    // Render all pages
    for (int i = 0; i < self.numberOfPages; i++) {
        UIGraphicsBeginPDFPage();
        
        CGContextRef currentContext = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(currentContext, _bgColor.CGColor);
        CGContextFillRect(currentContext, self.paperRect);

        if (i < titlePageCount && titleInfo) {
            // Render title pages
            [self drawTitlePageAtIndex:i inRect:bounds withTitleInfo:titleInfo];
        } else {
            // Calculate the correct content page index
            NSInteger contentPageIndex = i - titlePageCount;
            
            // Render regular content with the correct page index
            [self drawPageAtIndex:contentPageIndex inRect:bounds];
            
            // Only draw header for non-title pages
            if (headerInfo) {
                [self drawHeaderForPageAtIndex:contentPageIndex inRect:bounds withHeaderInfo:headerInfo];
            }
        }
    }

    *_numberOfPages = self.numberOfPages;

    UIGraphicsEndPDFContext();
    return pdfData;
}

- (void)drawTitlePageAtIndex:(NSInteger)index
                     inRect:(CGRect)rect
               withTitleInfo:(NSString *)titleInfo {
    NSData *htmlData = [titleInfo dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *options = @{ NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType };
    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithData:htmlData
                                                                          options:options
                                                               documentAttributes:nil
                                                                          error:nil];
    
    // Calculate offset based on page index to show correct portion of title content
    CGFloat pageHeight = rect.size.height;
    CGRect drawRect = rect;
    drawRect.origin.y = -index * pageHeight;
    [attributedString drawInRect:drawRect];
}

- (void)drawHeaderForPageAtIndex:(NSInteger)index
                         inRect:(CGRect)rect
                withHeaderInfo:(NSString *)headerInfo {
    // Draw the NSAttributedString
    NSData *htmlData = [headerInfo dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *options = @{ NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType };
    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithData:htmlData
                                                                          options:options
                                                               documentAttributes:nil
                                                                          error:nil];
    [attributedString drawInRect:rect];
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    if (index > 0) {
        CGContextMoveToPoint(context, CGRectGetMinX(rect) + 27, 110);
        CGContextAddLineToPoint(context, CGRectGetMaxX(rect) - 27, 110);
        CGContextSetStrokeColorWithColor(context, [UIColor blackColor].CGColor);
        CGContextStrokePath(context);
    }
}

@end

@implementation RNHTMLtoPDF {
    RCTEventDispatcher *_eventDispatcher;
    RCTPromiseResolveBlock _resolveBlock;
    RCTPromiseRejectBlock _rejectBlock;
    NSString *_html;
  NSString *_headerHtml;
    NSString *_titleHtml;
    NSString *_fileName;
    NSString *_filePath;
    UIColor *_bgColor;
    NSInteger *_numberOfPages;
    CGSize _PDFSize;
    WKWebView *_webView;
    float _paddingBottom;
    float _paddingTop;
    float _paddingLeft;
    float _paddingRight;
    BOOL _base64;
    BOOL autoHeight;
}

RCT_EXPORT_MODULE();

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

@synthesize bridge = _bridge;

- (instancetype)init
{
    if (self = [super init]) {
        _webView = [[WKWebView alloc] initWithFrame:self.bounds];
        _webView.navigationDelegate = self;
        [self addSubview:_webView];
        autoHeight = false;
    }
    return self;
}

RCT_EXPORT_METHOD(join:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    
    NSArray *pdfPaths = options[@"pdfPaths"];
    NSString *outputPath = options[@"outputPath"];
    
    // Validate input parameters
    if (!pdfPaths || ![pdfPaths isKindOfClass:[NSArray class]] || !outputPath) {
        reject(@"invalid_params", @"Missing or invalid required parameters", nil);
        return;
    }
    
    // Initialize a merged PDF document
    PDFDocument *mergedPDF = [[PDFDocument alloc] init];
    if (!mergedPDF) {
        reject(@"pdf_creation_failed", @"Failed to initialize PDF document", nil);
        return;
    }
    
    NSInteger currentPage = 0;
    
    // Iterate over the input PDF paths
    for (NSString *pdfPath in pdfPaths) {
        NSURL *pdfURL = [NSURL fileURLWithPath:pdfPath];
        PDFDocument *pdfDoc = [[PDFDocument alloc] initWithURL:pdfURL];
        
        if (!pdfDoc) {
            reject(@"invalid_pdf", [NSString stringWithFormat:@"Could not open PDF at path: %@", pdfPath], nil);
            return;
        }
        
        // Append all pages from the current PDF to the merged PDF
        for (NSInteger i = 0; i < pdfDoc.pageCount; i++) {
            PDFPage *page = [pdfDoc pageAtIndex:i];
            [mergedPDF insertPage:page atIndex:currentPage];
            currentPage++;
        }
    }
    
    // Save the merged PDF to the specified output path
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    BOOL saveSuccess = [mergedPDF writeToURL:outputURL];
    if (saveSuccess) {
        // Return result with output path and page count
        NSDictionary *result = @{
            @"outputPath": outputPath,
            @"pageCount": @(currentPage)
        };
        resolve(result);
    } else {
        reject(@"save_failed", @"Failed to save merged PDF", nil);
    }
}

RCT_EXPORT_METHOD(convert:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {

    if (options[@"html"]) {
        _html = [RCTConvert NSString:options[@"html"]];
    }

    if (options[@"headerHtml"]) {
        _headerHtml = [RCTConvert NSString:options[@"headerHtml"]];
    } else {
        _headerHtml = nil;
    }
    
    if (options[@"titleHtml"]) {
        _titleHtml = [RCTConvert NSString:options[@"titleHtml"]];
    } else {
        _titleHtml = nil;
    }

    if (options[@"fileName"]){
        _fileName = [RCTConvert NSString:options[@"fileName"]];
    } else {
        _fileName = [[NSProcessInfo processInfo] globallyUniqueString];
    }

    // Default Color
    _bgColor = [UIColor colorWithRed: (246.0/255.0) green:(245.0/255.0) blue:(240.0/255.0) alpha:1];
    if (options[@"bgColor"]){
        NSString *hex = [RCTConvert NSString:options[@"bgColor"]];
        hex = [hex uppercaseString];
        NSString *cString = [hex stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ((cString.length) == 7) {
            NSScanner *scanner = [NSScanner scannerWithString:cString];

            UInt32 rgbValue = 0;
            [scanner setScanLocation:1]; // Bypass '#' character
            [scanner scanHexInt:&rgbValue];

            _bgColor = [UIColor colorWithRed:((float)((rgbValue & 0xFF0000) >> 16))/255.0 \
                                       green:((float)((rgbValue & 0x00FF00) >>  8))/255.0 \
                                        blue:((float)((rgbValue & 0x0000FF) >>  0))/255.0 \
                                       alpha:1.0];
        }
    }

    if (options[@"directory"] && [options[@"directory"] isEqualToString:@"Documents"]){
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths objectAtIndex:0];

        _filePath = [NSString stringWithFormat:@"%@/%@.pdf", documentsPath, _fileName];
    } else {
        _filePath = [NSString stringWithFormat:@"%@%@.pdf", NSTemporaryDirectory(), _fileName];
    }

    if (options[@"base64"] && [options[@"base64"] boolValue]) {
        _base64 = true;
    } else {
        _base64 = false;
    }

    if (options[@"height"] && options[@"width"]) {
        float width = [RCTConvert float:options[@"width"]];
        float height = [RCTConvert float:options[@"height"]];
        _PDFSize = CGSizeMake(width, height);
    } else {
        _PDFSize = PDFSize;
    }

    if (options[@"paddingBottom"]) {
        _paddingBottom = [RCTConvert float:options[@"paddingBottom"]];
    } else {
        _paddingBottom = 10.0f;
    }

    if (options[@"paddingLeft"]) {
        _paddingLeft = [RCTConvert float:options[@"paddingLeft"]];
    } else {
        _paddingLeft = 10.0f;
    }

    if (options[@"paddingTop"]) {
        _paddingTop = [RCTConvert float:options[@"paddingTop"]];
    } else {
        _paddingTop = 10.0f;
    }

    if (options[@"paddingRight"]) {
        _paddingRight = [RCTConvert float:options[@"paddingRight"]];
    } else {
        _paddingRight = 10.0f;
    }

    if (options[@"padding"]) {
        _paddingTop = [RCTConvert float:options[@"padding"]];
        _paddingBottom = [RCTConvert float:options[@"padding"]];
        _paddingLeft = [RCTConvert float:options[@"padding"]];
        _paddingRight = [RCTConvert float:options[@"padding"]];
    }

    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSURL *baseURL = [NSURL fileURLWithPath:path];
    dispatch_async(dispatch_get_main_queue(), ^{
        [_webView loadHTMLString:_html baseURL:baseURL];
    });

    _resolveBlock = resolve;
    _rejectBlock = reject;

}
-(void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView.isLoading)
    return;
    
    UIPrintPageRenderer *render = [[UIPrintPageRenderer alloc] init];
    [render addPrintFormatter:webView.viewPrintFormatter startingAtPageAtIndex:0];
    
    // Define the printableRect and paperRect
    // If the printableRect defines the printable area of the page
    CGRect paperRect = CGRectMake(0, 0, _PDFSize.width, _PDFSize.height);
    CGRect printableRect = CGRectMake(_paddingLeft, _paddingTop, _PDFSize.width-(_paddingLeft + _paddingRight), _PDFSize.height-(_paddingBottom + _paddingTop));
    CGFloat headerHeight = (_headerHtml == nil || [_headerHtml isEqual: @""]) ? 0.0f : 100.0f;
    
    [render setValue:[NSValue valueWithCGRect:paperRect] forKey:@"paperRect"];
    [render setValue:[NSValue valueWithCGRect:printableRect] forKey:@"printableRect"];
    [render setValue:@(headerHeight) forKey:@"headerHeight"];
    
    NSData *pdfData = [render printToPDF:&_numberOfPages backgroundColor:_bgColor titleInfo:_titleHtml headerInfo:_headerHtml];
    
    if (pdfData) {
        NSString *pdfBase64 = @"";
        [pdfData writeToFile:_filePath atomically:YES];
        if (_base64) {
            pdfBase64 = [pdfData base64EncodedStringWithOptions:0];
        }
        NSDictionary *data = @{
            @"base64": pdfBase64,
            @"numberOfPages": [NSString stringWithFormat: @"%ld", (long)_numberOfPages],
            @"filePath": _filePath
        };
        _resolveBlock(data);
    } else {
        NSError *error;
        _rejectBlock(RCTErrorUnspecified, nil, RCTErrorWithMessage(error.description));
    }
}

@end
