package com.whyun.witv;

import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.preference.PreferenceManager;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.appcompat.app.AppCompatActivity;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.whyun.witv.player.PlayerConfigManager;

import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class SettingsActivity extends AppCompatActivity {
    private RecyclerView menuRecycler, contentRecycler;
    private MenuAdapter menuAdapter;
    private ContentAdapter contentAdapter;
    private String[] menuTitles = {"线路选择", "频道搜索", "播放设置", "列表订阅", "EPG订阅", "分类管理", "订阅管理", "显示设置", "偏好设置", "列表设置", "其他设置", "推送频道", "更多管理", "窗口编辑", "编辑菜单"};
    private int currentPos = 0;
    private SharedPreferences prefs;
    private static final String KEY_SUB_LIST = "sub_list";
    private static final String KEY_SELECTED_SUBS = "selected_subs";
    private static final String KEY_AUTO_RECONNECT = "auto_reconnect";
    private static final String KEY_NEED_RELOAD = "need_reload";
    private static final String KEY_SHOW_SPEED = "show_speed";
    private String localIp = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            setContentView(R.layout.activity_settings);
        } catch (Exception e) {
            Toast.makeText(this, "布局加载失败：" + e.getMessage(), Toast.LENGTH_LONG).show();
            finish();
            return;
        }

        prefs = PreferenceManager.getDefaultSharedPreferences(this);
        localIp = getLocalIpAddress();

        try {
            menuRecycler = findViewById(R.id.menu_recycler);
            contentRecycler = findViewById(R.id.content_recycler);

            if (menuRecycler == null || contentRecycler == null) {
                Toast.makeText(this, "资源ID找不到，请检查布局文件", Toast.LENGTH_LONG).show();
                finish();
                return;
            }

            menuRecycler.setLayoutManager(new LinearLayoutManager(this));
            menuAdapter = new MenuAdapter(menuTitles, pos -> {
                currentPos = pos;
                menuAdapter.setSelected(pos);
                showContent(pos);
            });
            menuRecycler.setAdapter(menuAdapter);

            contentRecycler.setLayoutManager(new LinearLayoutManager(this));
            contentAdapter = new ContentAdapter();
            contentRecycler.setAdapter(contentAdapter);

            int openTab = getIntent().getIntExtra("open_tab", -1);
            if (openTab >= 0 && openTab < menuTitles.length) {
                currentPos = openTab;
                menuAdapter.setSelected(openTab);
                showContent(openTab);
            } else {
                menuAdapter.setSelected(0);
                showContent(0);
            }
        } catch (Exception e) {
            Toast.makeText(this, "初始化失败：" + e.getMessage(), Toast.LENGTH_LONG).show();
            finish();
        }
    }

    private String getLocalIpAddress() {
        try {
            for (Enumeration<NetworkInterface> en = NetworkInterface.getNetworkInterfaces(); en.hasMoreElements();) {
                NetworkInterface intf = en.nextElement();
                for (Enumeration<InetAddress> enumIpAddr = intf.getInetAddresses(); enumIpAddr.hasMoreElements();) {
                    InetAddress inetAddress = enumIpAddr.nextElement();
                    if (!inetAddress.isLoopbackAddress() && inetAddress.getHostAddress().indexOf(':') == -1) {
                        return inetAddress.getHostAddress();
                    }
                }
            }
        } catch (Exception e) {}
        return "127.0.0.1";
    }

    private void showContent(int pos) {
        List<ContentItem> items = new ArrayList<>();
        try {
            switch (pos) {
                case 0: items.add(new ContentItem("线路选择", "点击选择", v -> showLineSelection())); break;
                case 1: items.add(new ContentItem("频道搜索", "点击搜索", v -> Toast.makeText(this, "频道搜索功能", Toast.LENGTH_SHORT).show())); break;
                case 2: buildPlaySettings(items); break;
                case 3: buildSubscriptionList(items); break;
                case 4: buildEpgSubscriptionList(items); break;
                case 5: items.add(new ContentItem("分类管理", "管理", v -> Toast.makeText(this, "分类管理", Toast.LENGTH_SHORT).show())); break;
                case 6: items.add(new ContentItem("订阅管理", "管理", v -> Toast.makeText(this, "订阅管理", Toast.LENGTH_SHORT).show())); break;
                case 7: buildDisplaySettings(items); break;
                case 8: items.add(new ContentItem("偏好设置", "点击", v -> showPreferenceSettings())); break;
                case 9: items.add(new ContentItem("列表设置", "点击", v -> showListSettings())); break;
                case 10: items.add(new ContentItem("其他设置", "点击", v -> showOtherSettings())); break;
                case 11: items.add(new ContentItem("推送频道", "推送", v -> Toast.makeText(this, "推送频道", Toast.LENGTH_SHORT).show())); break;
                case 12: items.add(new ContentItem("更多管理", "查看", v -> showMoreInfo())); break;
                case 13:
                    items.add(new ContentItem("进入窗口编辑模式", "点击后调整布局和字号", v -> {
                        Intent intent = new Intent(this, MainActivity.class);
                        intent.putExtra("edit_mode", true);
                        intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
                        startActivity(intent);
                        finish();
                    }));
                    break;
                case 14:
                    items.add(new ContentItem("编辑菜单（窗口编辑）", "点击进入编辑模式", v -> {
                        Intent intent = new Intent(this, MainActivity.class);
                        intent.putExtra("edit_mode", true);
                        intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
                        startActivity(intent);
                        finish();
                    }));
                    break;
            }
        } catch (Exception e) {
            Toast.makeText(this, "显示内容失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
        contentAdapter.setItems(items);
    }

    private void buildPlaySettings(List<ContentItem> items) {
        items.add(new ContentItem("解码方式", "点击设置", v -> showDecoderDialog()));
        items.add(new ContentItem("画面比例", "点击设置", v -> showAspectDialog()));
        items.add(new ContentItem("超时换源", "点击设置", v -> Toast.makeText(this, "超时换源功能", Toast.LENGTH_SHORT).show()));
        items.add(new ContentItem("断线重连", "点击切换", v -> toggleAutoReconnect()));
    }

    private void toggleAutoReconnect() {
        boolean current = prefs.getBoolean(KEY_AUTO_RECONNECT, true);
        boolean newVal = !current;
        prefs.edit().putBoolean(KEY_AUTO_RECONNECT, newVal).apply();
        Toast.makeText(this, "断线重连已" + (newVal ? "开启" : "关闭"), Toast.LENGTH_SHORT).show();
        showContent(2);
    }

    private void buildSubscriptionList(List<ContentItem> items) {
        items.add(new ContentItem("扫码输入", "点击二维码查看说明", v -> Toast.makeText(this, "IP: " + localIp + " 端口 9978", Toast.LENGTH_LONG).show()));
        items.add(new ContentItem("列表订阅", "http://" + localIp + ":9978/", v -> {}));

        Set<String> subSet = prefs.getStringSet(KEY_SUB_LIST, new HashSet<>());
        Set<String> selectedSet = new HashSet<>(prefs.getStringSet(KEY_SELECTED_SUBS, new HashSet<>()));

        if (subSet != null && !subSet.isEmpty()) {
            for (String entry : subSet) {
                String[] parts = entry.split("\\|\\|");
                String name = parts.length > 0 ? parts[0] : entry;
                String url = parts.length > 1 ? parts[1] : "";
                boolean isSelected = selectedSet.contains(entry);
                items.add(new ContentItem(name, url, isSelected, v -> {
                    Set<String> currentSelected = new HashSet<>(prefs.getStringSet(KEY_SELECTED_SUBS, new HashSet<>()));
                    if (currentSelected.contains(entry)) {
                        currentSelected.remove(entry);
                    } else {
                        currentSelected.add(entry);
                    }
                    prefs.edit().putStringSet(KEY_SELECTED_SUBS, currentSelected).apply();
                    prefs.edit().putBoolean(KEY_NEED_RELOAD, true).apply();
                    Toast.makeText(this, currentSelected.contains(entry) ? "已选中" : "已取消选中", Toast.LENGTH_SHORT).show();
                    showContent(3);
                }));
            }
        }

        items.add(new ContentItem("+ 添加订阅", "", v -> showAddSubscriptionDialog()));
    }

    private void buildEpgSubscriptionList(List<ContentItem> items) {
        items.add(new ContentItem("扫码输入", "点击二维码查看说明", v -> Toast.makeText(this, "EPG二维码功能", Toast.LENGTH_SHORT).show()));
        items.add(new ContentItem("EPG订阅", "http://" + localIp + ":9978/", v -> {}));
        String epgUrl = prefs.getString("epg_url", "");
        if (!epgUrl.isEmpty()) {
            items.add(new ContentItem("当前EPG", epgUrl, true, v -> {}));
        }
        items.add(new ContentItem("缓存", "每天8点", v -> Toast.makeText(this, "缓存设置", Toast.LENGTH_SHORT).show()));
        items.add(new ContentItem("[XML]epw", "", v -> {}));
        items.add(new ContentItem("+ 添加EPG", "", v -> showEpgDialog()));
    }

    private void buildDisplaySettings(List<ContentItem> items) {
        boolean showSpeed = prefs.getBoolean(KEY_SHOW_SPEED, true);
        items.add(new ContentItem("显示网速", showSpeed ? "开启" : "关闭", v -> {
            boolean current = prefs.getBoolean(KEY_SHOW_SPEED, true);
            prefs.edit().putBoolean(KEY_SHOW_SPEED, !current).apply();
            Toast.makeText(this, "网速显示已" + (!current ? "开启" : "关闭"), Toast.LENGTH_SHORT).show();
            showContent(7);
        }));
        items.add(new ContentItem("显示时间", "开启", v -> Toast.makeText(this, "功能待完善", Toast.LENGTH_SHORT).show()));
        items.add(new ContentItem("隐藏频道图标", "关闭", v -> Toast.makeText(this, "功能待完善", Toast.LENGTH_SHORT).show()));
        items.add(new ContentItem("隐藏底部图标", "关闭", v -> Toast.makeText(this, "功能待完善", Toast.LENGTH_SHORT).show()));
    }

    // ========== 添加订阅对话框（带异常捕获） ==========
    private void showAddSubscriptionDialog() {
        try {
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("添加列表订阅");

            LinearLayout layout = new LinearLayout(this);
            layout.setOrientation(LinearLayout.VERTICAL);
            layout.setPadding(50, 20, 50, 20);

            final EditText nameInput = new EditText(this);
            nameInput.setHint("名称（选填）");
            layout.addView(nameInput);

            final EditText urlInput = new EditText(this);
            urlInput.setHint("地址（必填）");
            layout.addView(urlInput);

            builder.setView(layout);
            builder.setPositiveButton("确定", null);
            builder.setNegativeButton("取消", null);

            AlertDialog dialog = builder.create();
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();

            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                try {
                    String name = nameInput.getText().toString().trim();
                    String url = urlInput.getText().toString().trim();

                    if (url.isEmpty()) {
                        Toast.makeText(this, "地址不能为空", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    if (name.isEmpty()) name = url;

                    String entry = name + "||" + url;
                    Set<String> subSet = new HashSet<>(prefs.getStringSet(KEY_SUB_LIST, new HashSet<>()));
                    subSet.add(entry);
                    prefs.edit().putStringSet(KEY_SUB_LIST, subSet).apply();

                    Set<String> selectedSet = new HashSet<>(prefs.getStringSet(KEY_SELECTED_SUBS, new HashSet<>()));
                    selectedSet.add(entry);
                    prefs.edit().putStringSet(KEY_SELECTED_SUBS, selectedSet).apply();

                    prefs.edit().putBoolean(KEY_NEED_RELOAD, true).apply();

                    Toast.makeText(this, "订阅已添加并选中", Toast.LENGTH_SHORT).show();
                    dialog.dismiss();
                    showContent(3);
                } catch (Exception e) {
                    Toast.makeText(this, "添加失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
                }
            });

            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setOnClickListener(v -> dialog.dismiss());
        } catch (Exception e) {
            Toast.makeText(this, "打开对话框失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    // ========== EPG 添加对话框（带异常捕获） ==========
    private void showEpgDialog() {
        try {
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("EPG订阅");

            LinearLayout layout = new LinearLayout(this);
            layout.setOrientation(LinearLayout.VERTICAL);
            layout.setPadding(50, 20, 50, 20);

            final EditText urlInput = new EditText(this);
            urlInput.setHint("EPG地址（XMLTV格式）");
            layout.addView(urlInput);

            builder.setView(layout);
            builder.setPositiveButton("确定", null);
            builder.setNegativeButton("取消", null);

            AlertDialog dialog = builder.create();
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();

            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                try {
                    String url = urlInput.getText().toString().trim();
                    if (url.isEmpty()) {
                        Toast.makeText(this, "地址不能为空", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    prefs.edit().putString("epg_url", url).apply();
                    Toast.makeText(this, "EPG地址已保存", Toast.LENGTH_SHORT).show();
                    dialog.dismiss();
                    showContent(4);
                } catch (Exception e) {
                    Toast.makeText(this, "保存失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
                }
            });

            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setOnClickListener(v -> dialog.dismiss());
        } catch (Exception e) {
            Toast.makeText(this, "打开对话框失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    // ========== 其他对话框（同样加保护） ==========
    private void showLineSelection() {
        try {
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("线路选择").setItems(new String[]{"源1", "源2", "源3"}, (d, w) ->
                    Toast.makeText(this, "选择线路" + (w + 1), Toast.LENGTH_SHORT).show());
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示线路失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void showDecoderDialog() {
        try {
            final String[] decoders = {"系统解码", "IJK硬解", "IJK软解", "EXO硬解", "EXO软解", "MPV硬解", "MPV软解", "自动"};
            int current = PlayerConfigManager.getDecoder();
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("解码方式")
                    .setSingleChoiceItems(decoders, current, (d, which) -> {
                        PlayerConfigManager.setDecoder(which);
                        Toast.makeText(this, "已保存", Toast.LENGTH_SHORT).show();
                        d.dismiss();
                    })
                    .setNegativeButton("取消", null);
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示解码器失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void showAspectDialog() {
        try {
            final String[] aspects = {"默认", "16:9", "4:3", "填充", "原始", "裁剪", "电影"};
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("画面比例")
                    .setSingleChoiceItems(aspects, 0, (d, which) -> {
                        PlayerConfigManager.setAspectRatio(aspects[which]);
                        Toast.makeText(this, "已保存", Toast.LENGTH_SHORT).show();
                        d.dismiss();
                    })
                    .setNegativeButton("取消", null);
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示比例失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void showPreferenceSettings() {
        try {
            final String[] items = {"记忆解码", "换台反转", "跨选分组", "关闭密码"};
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("偏好设置").setItems(items, (d, which) ->
                    Toast.makeText(this, items[which] + " (功能待完善)", Toast.LENGTH_SHORT).show());
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示偏好失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void showListSettings() {
        try {
            final String[] items = {"全局字体大小", "列表宽度", "底部信息栏宽度"};
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("列表设置").setItems(items, (d, which) ->
                    Toast.makeText(this, items[which] + " (功能待完善)", Toast.LENGTH_SHORT).show());
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示列表设置失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void showOtherSettings() {
        try {
            final String[] items = {"EPG缓存"};
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("其他设置").setItems(items, (d, which) ->
                    Toast.makeText(this, items[which] + " (功能待完善)", Toast.LENGTH_SHORT).show());
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示其他设置失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void showMoreInfo() {
        try {
            AlertDialog.Builder builder = new AlertDialog.Builder(this);
            builder.setTitle("更多管理").setMessage("Witv 1.0.0\n软件仅供测试").setPositiveButton("确定", null);
            AlertDialog dialog = builder.create();
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.show();
        } catch (Exception e) {
            Toast.makeText(this, "显示信息失败：" + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    // ========== Adapters ==========
    static class ContentItem {
        String title, subtitle;
        boolean isSelected;
        View.OnClickListener listener;

        ContentItem(String t, String s, View.OnClickListener l) {
            title = t;
            subtitle = s;
            isSelected = false;
            listener = l;
        }

        ContentItem(String t, String s, boolean sel, View.OnClickListener l) {
            title = t;
            subtitle = s;
            isSelected = sel;
            listener = l;
        }
    }

    static class MenuAdapter extends RecyclerView.Adapter<MenuAdapter.ViewHolder> {
        private String[] titles;
        private OnMenuClickListener listener;
        private int selected = -1;

        interface OnMenuClickListener {
            void onClick(int pos);
        }

        MenuAdapter(String[] t, OnMenuClickListener l) {
            titles = t;
            listener = l;
        }

        void setSelected(int pos) {
            selected = pos;
            notifyDataSetChanged();
        }

        @Override
        public ViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_menu, parent, false);
            return new ViewHolder(v);
        }

        @Override
        public void onBindViewHolder(ViewHolder holder, int position) {
            holder.text.setText(titles[position]);
            holder.itemView.setBackgroundColor(selected == position ? 0x33FFFFFF : 0x00000000);
            holder.itemView.setOnClickListener(v -> listener.onClick(position));
        }

        @Override
        public int getItemCount() {
            return titles.length;
        }

        static class ViewHolder extends RecyclerView.ViewHolder {
            TextView text;

            ViewHolder(View v) {
                super(v);
                text = v.findViewById(R.id.menu_text);
            }
        }
    }

    static class ContentAdapter extends RecyclerView.Adapter<ContentAdapter.ViewHolder> {
        private List<ContentItem> items = new ArrayList<>();

        void setItems(List<ContentItem> list) {
            items = list;
            notifyDataSetChanged();
        }

        @Override
        public ViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_content, parent, false);
            return new ViewHolder(v);
        }

        @Override
        public void onBindViewHolder(ViewHolder holder, int position) {
            ContentItem item = items.get(position);
            holder.title.setText(item.title);
            holder.subtitle.setText(item.subtitle);
            if (item.isSelected) {
                holder.title.setTextColor(Color.parseColor("#4CAF50"));
                holder.check.setVisibility(View.VISIBLE);
            } else {
                holder.title.setTextColor(Color.WHITE);
                holder.check.setVisibility(View.GONE);
            }
            holder.itemView.setOnClickListener(item.listener);
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        static class ViewHolder extends RecyclerView.ViewHolder {
            TextView title, subtitle, check;

            ViewHolder(View v) {
                super(v);
                title = v.findViewById(R.id.content_title);
                subtitle = v.findViewById(R.id.content_subtitle);
                check = v.findViewById(R.id.content_check);
            }
        }
    }
}
