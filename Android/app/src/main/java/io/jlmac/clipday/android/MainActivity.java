package io.jlmac.clipday.android;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.*;
import android.text.method.PasswordTransformationMethod;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import org.json.*;
import java.text.SimpleDateFormat;
import java.util.*;
import io.jlmac.clipday.core.Wire;

public final class MainActivity extends Activity {
    private static final int INK = Color.rgb(27, 45, 44), MUTED = Color.rgb(100, 119, 116), TEAL = Color.rgb(8, 127, 119);
    private ClipDayApp app;
    private LinearLayout settings, history, imageHistory, root;
    private TextView status, count, connectionTitle, setupResult;
    private EditText host, share, folder, username, password, code, composer, search;
    private Button connect, testConnection, send, refresh, settingsButton, privacyPause, syncPause;
    private boolean fieldsFilled, hadPair, settingsOpen = true, updatingDraft;
    private final Runnable update = this::render;
    private String historySignature = "", imageSignature = "";
    private final android.content.ClipboardManager.OnPrimaryClipChangedListener clipboardListener = () -> app.clipboardChanged();
    private int connectionRevision;
    private int dp(float n) { return Math.round(n * getResources().getDisplayMetrics().density); }
    private TextView text(String value, int sp, int color) {
        TextView t = new TextView(this); t.setText(value); t.setTextSize(sp); t.setTextColor(color); t.setLineSpacing(dp(2), 1); return t;
    }
    private GradientDrawable background(int color, int radius) { GradientDrawable b = new GradientDrawable(); b.setColor(color); b.setCornerRadius(dp(radius)); return b; }
    private LinearLayout vertical() { LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); return l; }
    private void add(LinearLayout parent, View child, int top) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2); p.topMargin = dp(top); parent.addView(child, p);
    }
    private LinearLayout card() {
        LinearLayout l = vertical(); l.setPadding(dp(18), dp(18), dp(18), dp(18)); l.setBackground(background(Color.WHITE, 20)); add(root, l, 14); return l;
    }
    private Button button(String title, boolean primary) {
        Button b = new Button(this); b.setText(title); b.setAllCaps(false); b.setTextSize(15); b.setMinHeight(dp(48)); b.setPadding(dp(16), dp(8), dp(16), dp(8));
        b.setTextColor(primary ? Color.WHITE : TEAL); b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary ? TEAL : Color.rgb(231, 244, 240))); return b;
    }
    private EditText input(LinearLayout parent, String label, String hint, int type) {
        add(parent, text(label, 13, MUTED), 14); EditText e = new EditText(this); e.setSingleLine(true); e.setTextSize(16); e.setTextColor(INK); e.setHint(hint);
        e.setInputType(type); e.setPadding(dp(12), dp(10), dp(12), dp(10)); e.setMinHeight(dp(48)); e.setBackground(background(Color.rgb(245, 248, 247), 10));
        e.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO); add(parent, e, 6); return e;
    }
    private void watch(EditText e, Runnable callback) { e.addTextChangedListener(new TextWatcher() {
        public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
        public void onTextChanged(CharSequence s, int start, int before, int count) { callback.run(); }
        public void afterTextChanged(Editable e) { }
    }); }
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); app = (ClipDayApp)getApplication(); connectionRevision = app.connectionRevision;
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setBackgroundColor(Color.rgb(242, 246, 245));
        root = vertical(); root.setPadding(dp(20), dp(20), dp(20), dp(28)); scroll.addView(root); setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((v, insets) -> {
            int top, bottom;
            if (Build.VERSION.SDK_INT >= 30) { android.graphics.Insets edges = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime()); top = edges.top; bottom = edges.bottom; }
            else { top = insets.getSystemWindowInsetTop(); bottom = insets.getSystemWindowInsetBottom(); }
            v.setPadding(0, top, 0, bottom); return insets;
        });
        TextView label = text("轻贴", 32, INK); label.setTypeface(null, Typeface.BOLD); add(root, label, 0);
        add(root, text("手机和电脑，接着用同一段文字或图片。当前 Android 仅支持 NAS 模式，不支持网盘文件夹模式。", 15, MUTED), 6);
        LinearLayout connection = card();
        LinearLayout heading = new LinearLayout(this); heading.setGravity(Gravity.CENTER_VERTICAL);
        connectionTitle = text("连接 NAS", 18, INK); connectionTitle.setTypeface(null, Typeface.BOLD);
        heading.addView(connectionTitle, new LinearLayout.LayoutParams(0, -2, 1));
        settingsButton = button("设置", false); heading.addView(settingsButton, new LinearLayout.LayoutParams(-2, -2)); connection.addView(heading);
        status = text("", 14, MUTED); add(connection, status, 6);
        settings = vertical(); add(connection, settings, 4);
        add(settings, text("1. 首次使用：电脑轻贴选择 NAS 模式，再创建同步空间。\n2. 手机仅加入已有空间，选择与电脑相同的 NAS 文件夹。\n3. 测试读写后，在电脑显示新的配对码并输入。", 13, MUTED), 8);
        Button aiHelp = button("复制安全的 AI 设置求助提示", false); add(settings, aiHelp, 8);
        aiHelp.setOnClickListener(v -> {
            String prompt = io.jlmac.clipday.core.SetupHelp.androidNas(Build.VERSION.SDK_INT);
            new AlertDialog.Builder(this).setTitle("先检查提示，再交给你的 AI").setMessage(prompt)
                .setNegativeButton("取消", null).setPositiveButton("复制提示", (dialog, which) -> {
                    app.localActivity(); ((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("轻贴设置帮助", prompt));
                    Toast.makeText(this, "已复制通用提示，未发送给任何 AI", Toast.LENGTH_LONG).show();
                }).show();
        });
        host = input(settings, "NAS 地址", "例如 192.168.1.10", android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI); host.setId(R.id.nas_host);
        share = input(settings, "共享名称", "例如 share（不是 Z: 盘符）", android.text.InputType.TYPE_CLASS_TEXT); share.setId(R.id.nas_share);
        folder = input(settings, "共享内的子文件夹 · 可留空", "例如 selfclip", android.text.InputType.TYPE_CLASS_TEXT); folder.setId(R.id.nas_folder);
        username = input(settings, "NAS 用户名", "有读写权限的 NAS 账号", android.text.InputType.TYPE_CLASS_TEXT); username.setId(R.id.nas_username);
        password = input(settings, "NAS 密码", "只加密保存在本机", android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD); password.setId(R.id.nas_password);
        password.setTransformationMethod(PasswordTransformationMethod.getInstance());
        password.setSaveEnabled(false);
        code = input(settings, "电脑上的 6 位配对码", "先在电脑轻贴里显示配对码", android.text.InputType.TYPE_CLASS_NUMBER); code.setId(R.id.pair_code); code.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(6)});
        code.setTextSize(26); code.setLetterSpacing(.16f);
        code.setSaveEnabled(false);
        testConnection = button("测试 NAS 连通与读写", false); testConnection.setId(R.id.test_connection); add(settings, testConnection, 14);
        testConnection.setOnClickListener(v -> connect(true));
        connect = button("连接并配对", true); connect.setId(R.id.connect); add(settings, connect, 14);
        watch(code, () -> { if (!app.setupBusy) connect.setText(app.paired() && code.getText().length() == 0 ? "保存并连接" : "连接并配对"); });
        add(settings, text("例如 NAS → share → selfclip：共享名称填 share，子文件夹填 selfclip。", 12, MUTED), 10);
        settingsButton.setOnClickListener(v -> { settingsOpen = !settingsOpen; settings.setVisibility(settingsOpen ? View.VISIBLE : View.GONE); });
        connect.setOnClickListener(v -> connect(false));
        setupResult = text("测试和配对的进度与结果会显示在这里。", 14, INK);
        setupResult.setId(R.id.setup_result); setupResult.setPadding(dp(12), dp(12), dp(12), dp(12));
        setupResult.setBackground(background(Color.rgb(231, 244, 240), 10));
        setupResult.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(connection, setupResult, 12);
        privacyPause = button("暂停隐私采集与收发", false); privacyPause.setId(R.id.privacy_pause); add(connection, privacyPause, 14);
        syncPause = button("只暂停同步", false); syncPause.setId(R.id.sync_pause); add(connection, syncPause, 8);
        privacyPause.setOnClickListener(v -> app.setPrivacyPaused(!app.privacyPaused));
        syncPause.setOnClickListener(v -> app.setSyncPaused(!app.syncPaused));
        add(connection, text("隐私暂停会停止新文字、图片保存与收发；只暂停同步时仍可保存到本机。两者不清空历史或队列，原有 24 小时到期规则不变。", 12, MUTED), 8);
        LinearLayout outgoing = card(); TextView outgoingTitle = text("发送文字", 18, INK); outgoingTitle.setTypeface(null, Typeface.BOLD); add(outgoing, outgoingTitle, 0);
        add(outgoing, text("从其他 App「分享 → 轻贴」，也可以在这里粘贴。", 13, MUTED), 6);
        composer = new EditText(this); composer.setId(R.id.composer); composer.setTextSize(16); composer.setTextColor(INK); composer.setGravity(Gravity.TOP);
        composer.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE); composer.setMinLines(2); composer.setMaxLines(6);
        composer.setHint("想发到电脑的文字…"); composer.setPadding(dp(12), dp(12), dp(12), dp(12)); composer.setBackground(background(Color.rgb(245, 248, 247), 12));
        composer.setSaveEnabled(false);
        add(outgoing, composer, 12); send = button("保存并发送", true); send.setId(R.id.send); add(outgoing, send, 10);
        watch(composer, () -> { if (!updatingDraft) { app.draft = composer.getText().toString(); app.localActivity(); } });
        send.setOnClickListener(v -> { hideKeyboard(); app.send(composer.getText().toString()); });
        LinearLayout received = card(); LinearLayout historyHeading = new LinearLayout(this); historyHeading.setGravity(Gravity.CENTER_VERTICAL);
        count = text("文字历史", 18, INK); count.setTypeface(null, Typeface.BOLD); historyHeading.addView(count, new LinearLayout.LayoutParams(0, -2, 1));
        refresh = button("刷新", false); refresh.setId(R.id.refresh); historyHeading.addView(refresh, new LinearLayout.LayoutParams(-2, -2)); received.addView(historyHeading);
        add(received, text("保留 24 小时 · 点「复制」后到其他 App 粘贴", 12, MUTED), 6);
        search = input(received, "搜索", "查找文字", android.text.InputType.TYPE_CLASS_TEXT); watch(search, () -> { historySignature = ""; imageSignature = ""; renderHistory(app.state()); renderImages(); });
        history = vertical(); add(received, history, 4);
        refresh.setOnClickListener(v -> app.refresh());
        LinearLayout pictures = card(); TextView pictureTitle = text("图片历史 · 自动同步", 18, INK); pictureTitle.setTypeface(null, Typeface.BOLD); add(pictures, pictureTitle, 0);
        add(pictures, text("Android 10 及以上仅在轻贴位于前台且获得焦点时读取剪贴板图片。复制后返回轻贴会自动保存和同步，不用手动发送。只支持静态 PNG/JPEG，单张最多 20 MiB。", 12, MUTED), 8);
        add(pictures, text("首次打开或补收的图片仅进历史；连续在线、无本地新操作时，10 秒内的新图片才自动放入剪贴板。文字接收规则不变。", 12, MUTED), 8);
        imageHistory = vertical(); add(pictures, imageHistory, 4);
        add(root, text("轻贴 · NAS 模式\n仅在打开时同步；后台不读取剪贴板，不使用辅助功能绕过系统限制。", 12, MUTED), 20);
        if (saved != null) {
            settingsOpen = saved.getBoolean("settingsOpen", true);
            for (EditText e : new EditText[]{host, share, folder, username}) if (saved.containsKey("f" + e.getId())) e.setText(saved.getString("f" + e.getId()));
            password.setText(app.setupPassword);
            fieldsFilled = saved.getBoolean("fieldsFilled") && app.ready; hadPair = saved.getBoolean("hadPair");
        } else acceptShare(getIntent());
        render();
    }
    @Override protected void onStart() { super.onStart(); ((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).addPrimaryClipChangedListener(clipboardListener); app.attach(update); }
    @Override public void onWindowFocusChanged(boolean focused) { super.onWindowFocusChanged(focused); if (app != null) app.setFocused(focused); }
    @Override protected void onStop() { ((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).removePrimaryClipChangedListener(clipboardListener); app.detach(update); super.onStop(); }
    @Override protected void onSaveInstanceState(Bundle b) {
        app.setupPassword = password.getText().toString();
        super.onSaveInstanceState(b); b.putBoolean("settingsOpen", settingsOpen); b.putBoolean("fieldsFilled", fieldsFilled); b.putBoolean("hadPair", hadPair);
        for (EditText e : new EditText[]{host, share, folder, username}) b.putString("f" + e.getId(), e.getText().toString());
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); acceptShare(intent); render(); }
    private void acceptShare(Intent intent) {
        if (!Intent.ACTION_SEND.equals(intent.getAction()) || !"text/plain".equals(intent.getType())) return;
        // On cold launch, wait for the encrypted persisted pause flags before accepting shared text.
        if (!app.ready) return;
        if (app.privacyPaused) {
            Toast.makeText(this, "隐私已暂停，未接收分享的文字。恢复后请重新分享。", Toast.LENGTH_LONG).show();
            intent.removeExtra(Intent.EXTRA_TEXT); intent.setAction(Intent.ACTION_MAIN); return;
        }
        CharSequence incoming = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
        if (incoming != null) {
            String value = incoming.toString();
            if (Wire.utf8(value).length <= Wire.MAX_TEXT) app.draft = value;
            else Toast.makeText(this, "每条文字最多 1 MB", Toast.LENGTH_LONG).show();
        }
        intent.removeExtra(Intent.EXTRA_TEXT); intent.setAction(Intent.ACTION_MAIN);
    }
    private void hideKeyboard() { ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(composer.getWindowToken(), 0); }
    private void connect(boolean testOnly) {
        try {
            String hostText = host.getText().toString().trim(); int port = 445;
            // A custom port is useful for local development and NAS configurations; IPv6 literals use brackets.
            if (hostText.matches("[^:]+:[0-9]+")) { int pos = hostText.lastIndexOf(':'); port = Integer.parseInt(hostText.substring(pos + 1)); hostText = hostText.substring(0, pos); }
            String user = username.getText().toString().trim(), domain = "";
            if (user.contains("\\")) { int split = user.indexOf('\\'); domain = user.substring(0, split); user = user.substring(split + 1); }
            JSONObject config = new JSONObject().put("host", hostText).put("port", port).put("share", share.getText().toString().trim())
                .put("folder", folder.getText().toString().trim()).put("username", user).put("domain", domain).put("password", password.getText().toString());
            hideKeyboard(); if (testOnly) app.testConnection(config); else app.connect(config, code.getText().toString());
        } catch (Exception e) { app.setupFeedback("请检查 NAS 地址和端口格式，例如 192.168.1.10 或 nas.example.com:445，不要填写网页链接。"); }
        render();
        setupResult.post(() -> setupResult.requestRectangleOnScreen(new android.graphics.Rect(0, 0, setupResult.getWidth(), setupResult.getHeight()), false));
    }
    private void render() {
        if (status == null) return;
        if (app.ready) acceptShare(getIntent());
        JSONObject state = app.state(); boolean paired = state.has("pair");
        if (!fieldsFilled && app.ready) {
            JSONObject cfg = state.optJSONObject("config");
            if (cfg != null) {
                host.setText(cfg.optString("host") + (cfg.optInt("port", 445) == 445 ? "" : ":" + cfg.optInt("port")));
                share.setText(cfg.optString("share")); folder.setText(cfg.optString("folder"));
                username.setText((cfg.optString("domain").isEmpty() ? "" : cfg.optString("domain") + "\\") + cfg.optString("username")); password.setText(cfg.optString("password"));
            }
            fieldsFilled = true;
        }
        if ((paired && !hadPair) || connectionRevision != app.connectionRevision) { settingsOpen = false; code.setText(""); connectionRevision = app.connectionRevision; }
        hadPair = paired; settings.setVisibility(settingsOpen ? View.VISIBLE : View.GONE);
        connectionTitle.setText(paired ? (app.online ? "●  NAS 已连接" : "●  已配对") : "连接 NAS"); connectionTitle.setTextColor(paired ? TEAL : INK);
        status.setText(app.statusText()); settingsButton.setText(settingsOpen ? "收起" : "设置");
        connect.setText(paired && code.getText().length() == 0 ? "保存并连接" : "连接并配对");
        boolean networkEnabled = !app.privacyPaused && !app.syncPaused;
        // Keep actions tappable so paused/loading/background-sync states explain why work cannot start.
        connect.setEnabled(!app.setupBusy); testConnection.setEnabled(!app.setupBusy);
        testConnection.setText(app.setupBusy && "test".equals(app.setupAction) ? "正在测试 NAS…" : "测试 NAS 连通与读写");
        if (app.setupBusy && "connect".equals(app.setupAction)) connect.setText("正在连接并配对…");
        for (EditText field : new EditText[]{host, share, folder, username, password, code}) field.setEnabled(!app.setupBusy);
        String feedback = app.setupMessage;
        if (feedback.isEmpty()) feedback = !app.ready ? app.statusText() : !networkEnabled ? "当前已暂停，请先恢复同步后再测试或配对。" : "测试和配对的进度与结果会显示在这里。";
        setupResult.setText(feedback);
        send.setEnabled(app.ready && paired && !app.saving && !app.privacyPaused);
        send.setText(app.saving ? "正在保存到本机…" : app.syncPaused ? "仅保存到本机" : "保存并发送");
        composer.setEnabled(app.ready && !app.privacyPaused);
        refresh.setEnabled(app.ready && paired && !app.busy && networkEnabled);
        privacyPause.setEnabled(app.ready && !app.pauseSaving); syncPause.setEnabled(app.ready && !app.pauseSaving);
        privacyPause.setText(app.privacyPaused ? "恢复隐私采集与收发" : "暂停隐私采集与收发");
        syncPause.setText(app.syncPaused ? "恢复同步" : "只暂停同步");
        if (!composer.getText().toString().equals(app.draft)) { updatingDraft = true; composer.setText(app.draft); updatingDraft = false; }
        renderHistory(state); renderImages(); if (app.focused) app.captureClipboard(false);
    }
    private void renderHistory(JSONObject state) {
        if (history == null) return;
        try {
            JSONArray records = state.optJSONArray("history"), pending = state.optJSONArray("pending");
            String query = search.getText().toString().toLowerCase(Locale.ROOT), signature = String.valueOf(records) + String.valueOf(pending) + query + System.currentTimeMillis() / 10000;
            if (signature.equals(historySignature)) return; historySignature = signature; history.removeAllViews();
            Set<String> waiting = new HashSet<>(); if (pending != null) for (int i = 0; i < pending.length(); i++) waiting.add(pending.getJSONObject(i).getString("id"));
            int shown = 0, total = 0;
            if (records != null) for (int i = 0; i < records.length(); i++) {
                JSONObject r = records.getJSONObject(i); if (r.getLong("expires") <= System.currentTimeMillis()) continue;
                if (!r.getString("text").toLowerCase(Locale.ROOT).contains(query)) continue;
                total++; if (shown >= 100) continue; shown++;
                LinearLayout row = vertical(); row.setPadding(0, dp(16), 0, dp(12));
                String time = new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date(r.getLong("created")));
                boolean own = r.getString("device").equals(state.optString("device"));
                String source = own ? "本机" : r.getString("name");
                String delivery = own ? (waiting.contains(r.getString("id")) ? " · 已保存本机，待上传" : " · 已上传 NAS，接收端未知") : " · 已接收到本机";
                add(row, text(time + " · " + source + delivery, 12, MUTED), 0);
                TextView preview = text(r.getString("text"), 16, INK); preview.setMaxLines(4); preview.setEllipsize(TextUtils.TruncateAt.END); add(row, preview, 8);
                LinearLayout actions = new LinearLayout(this); actions.setGravity(Gravity.END);
                Button more = button("查看", false), copy = button("复制", false); actions.addView(more); actions.addView(copy); add(row, actions, 8);
                copy.setOnClickListener(v -> copy(r)); more.setOnClickListener(v -> details(r));
                add(history, row, 0); View divider = new View(this); divider.setBackgroundColor(Color.rgb(234, 240, 238)); history.addView(divider, new LinearLayout.LayoutParams(-1, dp(1)));
            }
            count.setText("文字历史" + (total > 0 ? " · " + total : ""));
            if (shown == 0) add(history, text(query.isEmpty() ? "还没有文字\n电脑复制的内容会出现在这里。" : "没有找到匹配的文字", 15, MUTED), 24);
            else if (total > shown) add(history, text("显示最近 100 条，搜索可查找更多。", 12, MUTED), 12);
        } catch (Exception e) { status.setText("历史暂时无法显示，请重新打开轻贴。"); }
    }
    private void renderImages() {
        if (imageHistory == null) return;
        try {
            JSONObject state = app.imageState(); JSONArray records = state.optJSONArray("history"), pending = state.optJSONArray("pending");
            String query = search.getText().toString().toLowerCase(Locale.ROOT);
            String signature = String.valueOf(records) + pending + query + app.privacyPaused + System.currentTimeMillis()/10000;
            if (signature.equals(imageSignature)) return; imageSignature = signature; imageHistory.removeAllViews();
            Set<String> waiting = new HashSet<>(); if (pending != null) for (int i=0;i<pending.length();i++) waiting.add(pending.getString(i));
            int shown=0;
            if (records != null) for (int i=records.length()-1;i>=0;i--) {
                JSONObject r=records.getJSONObject(i); if(r.optLong("expires")<=System.currentTimeMillis()) continue;
                String id=r.getString("id"), source=r.optString("name");
                if(!query.isEmpty()&&!source.toLowerCase(Locale.ROOT).contains(query)&&!"图片 image png".contains(query)) continue;
                shown++; LinearLayout row=vertical(); row.setPadding(0,dp(16),0,dp(12));
                boolean own=r.optString("device").equals(state.optString("device"));
                String delivery=own?(waiting.contains(id)?"已保存本机，待上传":"已上传 NAS，接收端未知"):"已接收到本机";
                add(row,text(source+" · "+delivery,12,MUTED),0);
                add(row,text(r.optInt("width")+" × "+r.optInt("height")+" · "+Math.max(1,r.optLong("byteCount")/1024)+" KiB",12,MUTED),4);
                if(!app.privacyPaused && shown<=20){
                    ImageView preview=new ImageView(this);preview.setAdjustViewBounds(true);preview.setMaxHeight(dp(220));preview.setScaleType(ImageView.ScaleType.FIT_CENTER);preview.setContentDescription("同步图片预览");add(row,preview,8);
                    app.thumbnail(id,bitmap->{if(signature.equals(imageSignature)&&bitmap!=null)preview.setImageBitmap(bitmap);else if(bitmap!=null)bitmap.recycle();});
                }
                Button copy=button("复制图片",false);copy.setEnabled(!app.privacyPaused);add(row,copy,8);
                copy.setOnClickListener(v->{try{app.copyImage(id,false);if(Build.VERSION.SDK_INT<33)Toast.makeText(this,"已复制图片",Toast.LENGTH_SHORT).show();}catch(Exception e){Toast.makeText(this,"图片已过期或无法读取",Toast.LENGTH_SHORT).show();}});
                add(imageHistory,row,0);
            }
            if(shown==0)add(imageHistory,text("还没有图片 · 复制图片后返回轻贴即可自动同步。",14,MUTED),16);
        }catch(Exception e){status.setText("图片历史暂时无法显示，请重新打开轻贴。");}
    }
    private void copy(JSONObject record) {
        if (record.optLong("expires") <= System.currentTimeMillis()) { Toast.makeText(this, "这条文字已过期", Toast.LENGTH_SHORT).show(); return; }
        app.localActivity(); ((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("轻贴", record.optString("text")));
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show();
    }
    private void details(JSONObject record) {
        TextView value = text(record.optString("text"), 16, INK); value.setTextIsSelectable(true); value.setPadding(dp(24), dp(16), dp(24), dp(16));
        ScrollView scroller = new ScrollView(this); scroller.addView(value);
        new AlertDialog.Builder(this).setTitle("文字内容").setView(scroller).setNegativeButton("关闭", null).setPositiveButton("复制", (d, w) -> copy(record)).show();
    }
}
