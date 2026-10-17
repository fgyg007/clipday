# 历史独立云盘目标：已停用

此目录只保留此前源码检查点，不能再构建独立产品。MSBuild 会明确报错，历史 scripts/build-windows-drive.sh 会明确退出，不产生旧版安装包。

当前统一“轻贴”使用 Windows/ClipDay.Cloud 和 scripts/build-windows.sh，运行时选择 NAS、网盘同步文件夹或仅本机模式。说明及未完成的验收见 ../ClipDay.Cloud/UNIFIED-MODES.md。没有删除旧源码、发布资产或迁移用户数据。
