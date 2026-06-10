# DeviceIdle Manager

一个 KernelSU 模块，用于完全接管并保护 Android 设备的电池优化白名单配置 (`/data/system/deviceidle.xml`)。

## 功能

- **配置接管**：模块完全接管 `/data/system/deviceidle.xml` 的管理权
- **防篡改保护**：使用 `chattr +i` 和守护进程实时监控（inotifywait 优先，轮询兜底），防止任何程序修改配置
- **原始备份**：首次安装时自动读取并保存原始配置，模块更新时自动保留
- **WebUI 管理**：通过 KernelSU 内置 WebUI 直观管理白名单应用，支持搜索、添加、删除
- **导入/导出**：支持批量导入（合并或覆盖）和导出包名列表
- **一键恢复**：随时恢复到首次安装时的原始配置
- **状态监控**：实时显示守护进程运行状态、文件保护状态、白名单数量

## 安装

### 方式一：从源码构建

1. 克隆仓库
2. 运行 `build.ps1` 构建脚本生成 ZIP
3. 在 KernelSU Manager 中刷入生成的 ZIP

```powershell
.\build.ps1
```

### 方式二：直接刷入

1. 从 [Releases](https://github.com/Srythm/ksu_deviceidle_manager/releases) 下载最新 ZIP
2. 在 KernelSU Manager → 模块 → 从存储安装 中刷入
3. 模块会自动备份当前的 `deviceidle.xml`
4. 刷入后，守护进程会自动启动并开始保护

## 使用

1. 打开 KernelSU Manager
2. 找到 **DeviceIdle Manager** 模块
3. 点击模块名称进入 **WebUI**
4. 在 WebUI 中可以：
   - 查看当前白名单应用列表和状态
   - 搜索并添加/移除应用
   - 批量导入/导出包名列表
   - 一键恢复原始配置

### 导入格式

导入支持以下格式：
- 每行一个包名：`com.example.app`
- 粘贴 XML 内容（自动提取包名）
- 可选择「合并」或「覆盖」现有列表

## 工作原理

```
┌─────────────────────────────────────────────────┐
│                  启动流程                         │
├─────────────────────────────────────────────────┤
│  post-fs-data.sh  →  manager.sh backup-once     │
│                   →  manager.sh apply            │
│                                                 │
│  service.sh       →  manager.sh backup-once     │
│                   →  manager.sh apply            │
│                   →  启动守护进程                  │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│                  保护机制                         │
├─────────────────────────────────────────────────┤
│  1. 将模块管理的配置复制到 /data/system/          │
│     deviceidle.xml                              │
│  2. 设置文件权限 system:system 644               │
│  3. 设置 chattr +i 不可变标志                     │
│  4. 守护进程持续监控文件变化                        │
│     - 优先使用 inotifywait 实时监听                │
│     - 不可用时回退到 2 秒轮询                      │
│  5. 检测到修改立即恢复配置                         │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│              WebUI 写入流程                       │
├─────────────────────────────────────────────────┤
│  app.js → manager.sh set-list "pkg1,pkg2,..."   │
│         → write_xml_from_list (生成 XML)         │
│         → apply_active (同步到系统)               │
└─────────────────────────────────────────────────┘
```

## 文件说明

```
ksu_deviceidle_manager/
├── module.prop          # 模块元数据
├── customize.sh         # 安装脚本（首次备份，更新时保留旧备份）
├── post-fs-data.sh      # 启动早期：备份 + 应用配置
├── service.sh           # 守护进程：持续保护（inotifywait/轮询）
├── manager.sh           # 核心管理脚本（备份/应用/设置/状态）
├── action.sh            # KernelSU 操作按钮：快速状态检查
├── uninstall.sh         # 卸载时恢复原始配置
├── sepolicy.rule        # SELinux 规则
├── build.ps1            # Windows 构建脚本
└── webroot/             # WebUI 文件
    ├── index.html       # 界面结构
    ├── styles.css       # 样式（支持暗色模式）
    └── app.js           # 逻辑（兼容多种 KernelSU API）
```

### manager.sh 命令

| 命令 | 说明 |
|------|------|
| `manager.sh backup-once` | 首次备份原始配置（已有备份则跳过） |
| `manager.sh apply` | 将活跃配置同步到系统文件 |
| `manager.sh set-list "pkg1,pkg2"` | 设置白名单包名列表（逗号分隔） |
| `manager.sh list` | 输出当前白名单包名 |
| `manager.sh original-list` | 输出原始备份中的包名 |
| `manager.sh status` | 输出状态（count/protected/daemon/target_match） |
| `manager.sh restore-original` | 恢复为首次安装时的原始配置 |

## 注意事项

- 此模块需要 KernelSU 支持 WebUI 功能（v0.7.0+）
- 部分 ROM 可能不支持 `chattr +i`，此时依赖守护进程轮询保护
- 请勿将此模块与其他修改 `deviceidle.xml` 的模块同时使用
- 恢复原始配置后，守护进程仍会继续运行并保护文件
- 模块更新时会自动保留首次备份，无需重新配置

## 兼容性

- **KernelSU**: v0.7.0 及以上（支持 WebUI）
- **Android**: Android 9.0 (API 28) 及以上
- **架构**: arm64, arm, x86_64, x86

## 构建

```powershell
# Windows
.\build.ps1

# 或手动打包
# 将除 build.ps1、.git、README.md 外的所有文件打包为 ZIP
```

生成的 ZIP 文件名格式：`ksu_deviceidle_manager-v1.0.0.zip`

## 更新日志

### v1.0.0
- 初始版本
- 支持接管 deviceidle.xml
- 支持 WebUI 管理（添加/删除/搜索/导入/导出）
- 支持防篡改保护（chattr + inotifywait/轮询）
- 支持模块更新时保留原始备份
- 支持暗色模式

## 开源协议

MIT License
