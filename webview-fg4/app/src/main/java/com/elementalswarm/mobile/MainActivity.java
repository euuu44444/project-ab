package com.elementalswarm.mobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.DisplayCutout;
import android.view.Display;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.JsResult;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.Date;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import org.json.JSONObject;

/** Offline, dependency-free Android shell. Gameplay remains in assets/index.html. */
public final class MainActivity extends Activity {
    private static final String APP_URL = "https://appassets.androidplatform.net/assets/index.html";
    private static final int EXPORT_DOCUMENT = 101;
    private static final int IMPORT_DOCUMENT = 102;
    private static final int MAX_SAVE_BYTES = 4 * 1024 * 1024;
    private static final String CSP = "default-src 'none'; script-src 'unsafe-inline' blob:; "
        + "worker-src blob:; style-src 'unsafe-inline'; img-src 'self' data: blob:; "
        + "font-src data:; media-src data: blob:; connect-src 'none'; "
        + "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";

    private WebView webView;
    private FrameLayout root;
    private boolean pageReady;
    private boolean resumed;
    private boolean exitDialogShowing;
    private boolean documentPickerOpen;
    private boolean rendererGone;
    private int lifecycleEpoch;
    private byte[] pendingExport;
    private final ArrayDeque<String> pendingScripts = new ArrayDeque<String>();
    private OnBackInvokedCallback backCallback;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(7,16,28));
        setContentView(root);
        configureInsets();
        try {
            webView = new WebView(this);
            webView.setBackgroundColor(Color.rgb(7,16,28));
            webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
            root.addView(webView, new FrameLayout.LayoutParams(-1,-1));
            WebSettings settings = webView.getSettings();
            settings.setJavaScriptEnabled(true);
            settings.setDomStorageEnabled(true);
            settings.setAllowFileAccess(false);
            settings.setAllowContentAccess(false);
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
            settings.setJavaScriptCanOpenWindowsAutomatically(false);
            settings.setSupportMultipleWindows(false);
            settings.setUseWideViewPort(true);
            settings.setLoadWithOverviewMode(false);
            settings.setSupportZoom(true);
            settings.setBuiltInZoomControls(true);
            settings.setDisplayZoomControls(false);
            settings.setTextZoom(100);
            settings.setMediaPlaybackRequiresUserGesture(true);
            WebView.setWebContentsDebuggingEnabled(false);
            webView.addJavascriptInterface(new NativeBridge(), "ElementalNative");
            webView.setWebViewClient(new LocalClient());
            webView.setWebChromeClient(new LocalChrome());
            webView.loadUrl(APP_URL);
        } catch (RuntimeException failure) {
            showFatal("Android System WebView を更新してから、もう一度起動してください。");
        }
        if (Build.VERSION.SDK_INT >= 33) {
            backCallback = new OnBackInvokedCallback() {
                @Override public void onBackInvoked() { handleBack(); }
            };
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, backCallback);
        }
        enterImmersiveMode();
    }

    private void configureInsets() {
        if (Build.VERSION.SDK_INT >= 30) getWindow().setDecorFitsSystemWindows(false);
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override public WindowInsets onApplyWindowInsets(View view, WindowInsets insets) {
                int left, top, right, bottom;
                if (Build.VERSION.SDK_INT >= 30) {
                    android.graphics.Insets bars = insets.getInsets(
                        WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                    android.graphics.Insets gestures = insets.getInsets(WindowInsets.Type.mandatorySystemGestures());
                    left = bars.left; top = bars.top; right = bars.right;
                    bottom = Math.max(bars.bottom, gestures.bottom);
                } else {
                    left=insets.getSystemWindowInsetLeft(); top=insets.getSystemWindowInsetTop();
                    right=insets.getSystemWindowInsetRight(); bottom=insets.getSystemWindowInsetBottom();
                    DisplayCutout cutout=insets.getDisplayCutout();
                    if(cutout!=null){left=Math.max(left,cutout.getSafeInsetLeft());
                        top=Math.max(top,cutout.getSafeInsetTop());
                        right=Math.max(right,cutout.getSafeInsetRight());
                        bottom=Math.max(bottom,cutout.getSafeInsetBottom());}
                    bottom=Math.max(bottom,insets.getMandatorySystemGestureInsets().bottom);
                }
                view.setPadding(left,top,right,bottom);
                if(Build.VERSION.SDK_INT>=30)return WindowInsets.CONSUMED;
                return insets.consumeSystemWindowInsets().consumeDisplayCutout();
            }
        });
    }

    private void enterImmersiveMode() {
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController controller=getWindow().getInsetsController();
            if(controller!=null){
                controller.hide(WindowInsets.Type.systemBars());
                controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
        root.requestApplyInsets();
    }

    @Override public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        enterImmersiveMode();
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if(focused)enterImmersiveMode();
    }

    @Override protected void onResume() {
        super.onResume();
        resumed=true; lifecycleEpoch++;
        if(webView!=null&&!rendererGone){
            webView.resumeTimers(); webView.onResume();
            if(pageReady){
                webView.evaluateJavascript("window.elementalAndroid&&elementalAndroid.resume()",null);
                flushScripts();
            }
        }
        enterImmersiveMode();
    }

    private void pauseWebContent() {
        if(webView==null||rendererGone)return;
        final int epoch=++lifecycleEpoch;
        webView.onPause();
        if(pageReady){
            webView.evaluateJavascript("window.elementalAndroid&&elementalAndroid.pause()",new ValueCallback<String>(){
                @Override public void onReceiveValue(String ignored){
                    // A late pause callback must never suspend a resumed activity.
                    if(!resumed&&lifecycleEpoch==epoch&&webView!=null&&!rendererGone)webView.pauseTimers();
                }
            });
        } else webView.pauseTimers();
    }

    @Override protected void onPause() {
        resumed=false;
        pauseWebContent();
        super.onPause();
    }

    @Override public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if(level>=TRIM_MEMORY_RUNNING_LOW&&resumed&&pageReady&&webView!=null&&!rendererGone)
            webView.evaluateJavascript("elementalAndroid.memoryPressure()",null);
    }

    @Override protected void onDestroy() {
        resumed=false; lifecycleEpoch++;
        if(Build.VERSION.SDK_INT>=33&&backCallback!=null)
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(backCallback);
        if(webView!=null){
            root.removeView(webView);
            webView.removeJavascriptInterface("ElementalNative");
            webView.destroy(); webView=null;
        }
        pendingExport=null; pendingScripts.clear();
        super.onDestroy();
    }

    @Override public void onBackPressed() { handleBack(); }

    private void handleBack() {
        if(exitDialogShowing||documentPickerOpen)return;
        if(pageReady&&webView!=null&&!rendererGone){
            webView.evaluateJavascript("window.elementalAndroid?elementalAndroid.back():false",new ValueCallback<String>(){
                @Override public void onReceiveValue(String handled){if(!"true".equals(handled))confirmExit();}
            });
        } else confirmExit();
    }

    private void confirmExit() {
        if(exitDialogShowing||isFinishing())return;
        exitDialogShowing=true;
        new AlertDialog.Builder(this).setTitle("ゲームを終了しますか？")
            .setMessage("実績・設定は保存されます。進行中の戦闘は保存されません。")
            .setPositiveButton("終了",(dialog,which)->finish())
            .setNegativeButton("キャンセル",null)
            .setOnDismissListener(dialog->exitDialogShowing=false).show();
    }

    private void enqueueScript(String script) {
        pendingScripts.add(script);
        flushScripts();
    }

    private void flushScripts() {
        if(!resumed||!pageReady||webView==null||rendererGone)return;
        while(!pendingScripts.isEmpty())webView.evaluateJavascript(pendingScripts.removeFirst(),null);
    }

    private void saveMessage(String text,boolean ok) {
        enqueueScript("elementalAndroid.saveResult("+JSONObject.quote(text)+","+ok+")");
    }

    private void showFatal(String message) {
        if(isFinishing()||rendererGone)return;
        rendererGone=true; pageReady=false;
        if(webView!=null){root.removeView(webView);webView.destroy();webView=null;}
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);
        int padding=(int)(24*getResources().getDisplayMetrics().density);
        box.setPadding(padding,padding,padding,padding);
        TextView text=new TextView(this);text.setText(message);text.setTextColor(Color.WHITE);text.setTextSize(18);
        Button retry=new Button(this);retry.setText("再起動");retry.setOnClickListener(v->recreate());
        box.addView(text);box.addView(retry);root.addView(box,new FrameLayout.LayoutParams(-1,-1));
    }

    private final class LocalClient extends WebViewClient {
        @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){
            return !APP_URL.equals(request.getUrl().toString());
        }
        @Override public boolean shouldOverrideUrlLoading(WebView view,String url){return !APP_URL.equals(url);}
        @Override public WebResourceResponse shouldInterceptRequest(WebView view,WebResourceRequest request){
            if(APP_URL.equals(request.getUrl().toString())){
                try {
                    Map<String,String> headers=new HashMap<String,String>();
                    headers.put("Content-Security-Policy",CSP);
                    headers.put("Cache-Control","no-store");
                    headers.put("X-Content-Type-Options","nosniff");
                    return new WebResourceResponse("text/html","UTF-8",200,"OK",headers,getAssets().open("index.html"));
                } catch(Exception error) {
                    runOnUiThread(()->showFatal("ゲームデータを開けませんでした。アプリを再インストールしてください。"));
                }
            }
            // Local content only. No external navigation, HTTP, or file/content URLs.
            return new WebResourceResponse("text/plain","UTF-8",403,"Forbidden",null,
                new ByteArrayInputStream(new byte[0]));
        }
        @Override public void onReceivedError(WebView view,WebResourceRequest request,WebResourceError error){
            if(request.isForMainFrame())showFatal("ゲームを読み込めませんでした。Android System WebView を更新してください。");
        }
        @Override public void onPageFinished(WebView view,String url){
            if(!APP_URL.equals(url)||rendererGone)return;
            view.evaluateJavascript("typeof window.elementalAndroid==='object'",new ValueCallback<String>(){
                @Override public void onReceiveValue(String ready){
                    if(!"true".equals(ready))showFatal("ゲームを実行できませんでした。Android System WebView を最新版に更新してください。");
                }
            });
        }
        @Override public boolean onRenderProcessGone(WebView view,RenderProcessGoneDetail detail){
            showFatal("描画プロセスが終了しました。再起動してください。実績・設定は保持されています。");return true;
        }
    }

    private final class LocalChrome extends WebChromeClient {
        @Override public boolean onConsoleMessage(ConsoleMessage message){return true;}
        @Override public boolean onJsConfirm(WebView view,String url,String message,final JsResult result){
            if(!APP_URL.equals(url)){result.cancel();return true;}
            new AlertDialog.Builder(MainActivity.this).setMessage(message)
                .setPositiveButton("続ける",(dialog,which)->result.confirm())
                .setNegativeButton("キャンセル",(dialog,which)->result.cancel())
                .setOnCancelListener(dialog->result.cancel()).show();
            return true;
        }
        @Override public boolean onJsAlert(WebView view,String url,String message,final JsResult result){
            if(!APP_URL.equals(url)){result.cancel();return true;}
            new AlertDialog.Builder(MainActivity.this).setMessage(message)
                .setPositiveButton("OK",(dialog,which)->result.confirm())
                .setOnCancelListener(dialog->result.confirm()).show();return true;
        }
    }

    public final class NativeBridge {
        @JavascriptInterface public void setFrameGenerationActive(final boolean enabled){
            runOnUiThread(()->{
                if(webView==null||rendererGone)return;
                Display display=webView.getDisplay();if(display==null)return;
                WindowManager.LayoutParams parameters=getWindow().getAttributes();
                parameters.preferredDisplayModeId=0;
                parameters.preferredRefreshRate=0;
                if(enabled){
                    Display.Mode current=display.getMode(),best=null;float bestDistance=Float.MAX_VALUE;
                    for(Display.Mode candidate:display.getSupportedModes()){
                        float rate=candidate.getRefreshRate();
                        if(candidate.getPhysicalWidth()!=current.getPhysicalWidth()||candidate.getPhysicalHeight()!=current.getPhysicalHeight())continue;
                        if(rate<89f||rate>165f)continue;
                        float distance=Math.abs(rate-120f);
                        if(distance<bestDistance){best=candidate;bestDistance=distance;}
                    }
                    if(best!=null){parameters.preferredDisplayModeId=best.getModeId();parameters.preferredRefreshRate=best.getRefreshRate();}
                }
                getWindow().setAttributes(parameters);
            });
        }
        @JavascriptInterface public void ready(String version){
            runOnUiThread(()->{
                if(webView==null||!APP_URL.equals(webView.getUrl())||rendererGone)return;
                pageReady=true;
                if(resumed){webView.evaluateJavascript("elementalAndroid.resume()",null);flushScripts();}
                else pauseWebContent();
            });
        }
        @JavascriptInterface public void exportSave(final String text){
            if(text==null||text.length()>MAX_SAVE_BYTES)return;
            final byte[] bytes=text.getBytes(StandardCharsets.UTF_8);
            if(bytes.length>MAX_SAVE_BYTES)return;
            runOnUiThread(()->{
                if(!pageReady||documentPickerOpen||pendingExport!=null)return;
                pendingExport=bytes;documentPickerOpen=true;
                String date=new SimpleDateFormat("yyyy-MM-dd",Locale.ROOT).format(new Date());
                Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/json").putExtra(Intent.EXTRA_TITLE,"elemental-swarm-save-"+date+".json");
                try{startActivityForResult(intent,EXPORT_DOCUMENT);}
                catch(ActivityNotFoundException failure){documentPickerOpen=false;pendingExport=null;
                    saveMessage("保存先を選択できません。クリップボードへのコピーを使用してください。",false);}
            });
        }
        @JavascriptInterface public void importSave(){
            runOnUiThread(()->{
                if(!pageReady||documentPickerOpen)return;
                documentPickerOpen=true;
                Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*").putExtra(Intent.EXTRA_MIME_TYPES,new String[]{"application/json","text/plain","application/octet-stream"});
                try{startActivityForResult(intent,IMPORT_DOCUMENT);}
                catch(ActivityNotFoundException failure){documentPickerOpen=false;
                    saveMessage("ファイルを選択できません。JSONの貼り付けを使用してください。",false);}
            });
        }
        @JavascriptInterface public void copySave(final String text){
            if(text==null||text.length()>MAX_SAVE_BYTES)return;
            runOnUiThread(()->{
                if(!pageReady)return;
                ClipboardManager manager=(ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
                if(manager!=null)manager.setPrimaryClip(ClipData.newPlainText("Elemental Swarm save",text));
            });
        }
    }

    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(request!=EXPORT_DOCUMENT&&request!=IMPORT_DOCUMENT)return;
        documentPickerOpen=false;
        final byte[] export=pendingExport;
        pendingExport=null;
        final Uri uri=data==null?null:data.getData();
        if(result!=RESULT_OK||uri==null){saveMessage("ファイル操作をキャンセルしました。",false);return;}
        new Thread(()->{
            try {
                if(request==EXPORT_DOCUMENT){
                    if(export==null)throw new IllegalStateException("保存するデータがありません。");
                    try(OutputStream output=getContentResolver().openOutputStream(uri,"wt")){
                        if(output==null)throw new IllegalStateException("保存先を開けません。");
                        output.write(export);output.flush();
                    }
                    runOnUiThread(()->saveMessage("ファイルとして保存しました。",true));
                } else {
                    String text;
                    try(InputStream input=getContentResolver().openInputStream(uri);
                        ByteArrayOutputStream output=new ByteArrayOutputStream()){
                        if(input==null)throw new IllegalStateException("ファイルを開けません。");
                        byte[] buffer=new byte[8192];int count,total=0;
                        while((count=input.read(buffer))!=-1){total+=count;
                            if(total>MAX_SAVE_BYTES)throw new IllegalStateException("ファイルが大きすぎます（上限4 MiB）。");
                            output.write(buffer,0,count);}
                        text=new String(output.toByteArray(),StandardCharsets.UTF_8);
                    }
                    if(text.startsWith("\uFEFF"))text=text.substring(1);
                    new JSONObject(text); // Reject non-JSON before passing it to the page.
                    final String script="elementalAndroid.loadSave("+JSONObject.quote(text)+")";
                    runOnUiThread(()->enqueueScript(script));
                }
            } catch(Exception error){
                runOnUiThread(()->saveMessage("ファイルを処理できませんでした。JSON形式・空き容量・アクセス権を確認してください。",false));
            }
        },"swarm-save-io").start();
    }
}
