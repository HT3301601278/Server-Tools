# Server Tools

服务器管理脚本。目前主要脚本：

```text
server_user_admin.sh
```

用于在服务器内部以 `root` 用户管理普通用户、sudo 权限、免密 sudo 和 SSH 公钥。

## 支持系统

```text
Ubuntu
CentOS
```

Ubuntu 使用 `sudo` 组，CentOS 使用 `wheel` 组。其他系统会直接退出。

## 一行安装并运行

```bash
curl -fsSL https://raw.githubusercontent.com/HT3301601278/Server-Tools/refs/heads/master/server_user_admin.sh -o /usr/local/sbin/useradmin && chmod +x /usr/local/sbin/useradmin && useradmin
```

以后直接运行：

```bash
useradmin
```

临时执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HT3301601278/Server-Tools/refs/heads/master/server_user_admin.sh)
```

## 功能

主菜单输入数字进入功能。进入用户列表后，使用 `↑/↓` 移动，空格勾选/取消，回车执行，`q` 取消。

```text
1. 查看普通用户
2. 查看用户详情
3. 添加用户
4. 删除用户
5. 加入 sudo/wheel 组
6. 移出 sudo/wheel 组
7. 开启免密 sudo
8. 关闭免密 sudo
9. 添加 SSH 公钥
0. 退出
```

## 说明

免密 sudo 会写入：

```text
/etc/sudoers.d/90-user-用户名
```

删除用户使用：

```bash
userdel -r 用户名
```

删除前需要先用空格勾选用户，回车后输入 `y` 确认。

脚本会拒绝删除 `root` 和 UID 小于 1000 的系统用户。
