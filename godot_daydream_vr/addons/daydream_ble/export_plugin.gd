@tool
extends EditorExportPlugin

const AAR_PATH := "res://addons/daydream_ble/bin/daydream_ble.aar"


func _get_name() -> String:
	return "DaydreamBle"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
	if not FileAccess.file_exists(AAR_PATH):
		push_error("DaydreamBle: не найден %s. Соберите плагин: android_plugin/build_plugin.sh" % AAR_PATH)
		return PackedStringArray()
	return PackedStringArray([AAR_PATH])
