# 参与开发

## 环境与模块

在 macOS 13+ 上安装 Apple Command Line Tools。项目通过系统 Swift 编译器构建，无包管理器或第三方依赖。

仓库地址为 https://github.com/lxfu1/disk-lens，默认分支为 `main`。克隆、构建和启动命令见 [README](README.md)。

- `AppModel` 管理界面状态；`ContentView`、`SettingsView` 和 `TreemapView` 提供视图。
- `IndexCoordinator` 分离索引写入、查询和事件监听队列。
- `DiskIndex` 实现SQLite索引；`IndexSchema` 为应用与离线迁移共享建表定义。
- `DirectoryReader` 使用系统批量元数据API，保留逐项读取回退。
- `FileActions` 统一列表和地图的打开方式；`LoginStartup` 对接系统登录项。
- `AppBrand` 绘制原创品牌图形；其他界面符号由macOS提供，不导出成项目品牌资产。

## 验证

按改动范围选择最小检查。下表不是要求全部执行的检查清单。

| 改动 | 命令 |
| --- | --- |
| 根目录待办、导航、查询/维护反馈 | `bash scripts/check-release.sh` |
| Treemap 布局、键盘、菜单、辅助功能 | `bash scripts/check-treemap.sh` |
| 登录启动与设置 | `bash scripts/check-settings.sh` |
| 计费、链接、取消、废纸篓边界 | `bash scripts/check-core.sh` |
| 增量更新与恢复 | `bash scripts/check-incremental.sh` |
| 分页、身份、差量、枚举恢复 | `bash scripts/check-optimizations.sh --index-only` |
| 真实FSEvents与协调器 | `bash scripts/check-events.sh` |
| 存储与迁移 | `bash scripts/check-storage.sh` |
| 首次扫描 | `bash scripts/check-first-scan.sh` |

## 更新文档截图

使用当前生产视图、合成目录及隔离偏好生成截图，需要已登录的 macOS 图形会话及屏幕录制权限。在项目根目录运行：

```sh
bash scripts/update-screenshots.sh
```

该命令只执行主界面与设置的两组定向检查，随后更新 `docs/preview.png`、`docs/screenshots/` 和 `docs/icon.png`。设置页使用替身登录服务，不修改系统登录项；不会扫描用户目录。截图会短暂显示演示窗口，运行后应检查文字、布局、深浅模式与隐私，再提交资源。

文档截图会自动添加适配深浅背景的细描边，保留原始圆角与透明区域；描边写入 PNG，因此 GitHub 的中英文 README 均可直接显示，无需依赖 HTML 样式。未加描边的原图保存在 `.build/documentation-previews/`。

只需捕获主界面进行开发检查时，可运行：

```sh
DISKLENS_CAPTURE_UI=1 bash scripts/check-release.sh
```

生成 `.build/previews/` 下的普通、小窗口与深色模式截图，全部使用虚构路径；可通过 `DISKLENS_CAPTURE_DIR` 指定输出目录。`check-settings.sh` 使用相同变量生成 `settings.png`；地图检查也支持 `DISKLENS_CAPTURE_UI`。常规测试不截屏、不启动外部应用；测试数据库位于临时目录。

动画启停可用 `DISKLENS_CAPTURE_ANIMATION=1 bash scripts/check-release.sh` 验证；需要图形会话，实际窗口的局部渲染证据保存在 `.build/animation-check/`，不读取用户文件。

`check-performance.sh`含较大夹具，应在确有性能问题且同意耗时验证时再执行。测试样本的热缓存耗时不能外推到真实大目录。

## 提交范围

修复应包含必要回归测试及过时实现清理。数据迁移必须保留中断恢复和失败回退，不能通过删除用户索引掩盖错误。UI操作应覆盖加载、错误、空结果及重复点击；文件操作不能在未确认时删除用户文件。

提交前检查差异，排除`.build/`、`dist/`、数据库、个人路径、临时日志和真实文件列表。报告问题时提供macOS/应用版本、复现步骤、索引是否完整及可公开的合成示例。

`.gitignore` 已排除构建产物、SQLite 数据与侧文件、本地环境文件和日志；`.gitattributes` 统一文本换行为 LF，并将 PNG/ICNS 作为二进制资源处理。Git 作者信息沿用个人配置，项目不会覆盖全局身份或凭证。

提交前仅运行与改动相关的检查，并使用 `git diff --check` 检查空白问题。通过 Pull Request 描述具体问题、改动结果、已执行验证及尚未覆盖的场景。

发布应用前还需实际验证系统登录项、通知权限、目标macOS/架构及签名公证。当前本地构建与测试不代表这些分发环节已完成。
