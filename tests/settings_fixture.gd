extends RefCounted
## Shared plumbing for the settings suites: one throwaway file, and the stores that own it.
##
## Two copies of this drifted the moment there were two settings suites — the same four helpers,
## one different temp path — so there is one.

const Settings := preload("res://addons/spacesim/settings/settings.gd")

const TEST_PATH := "user://test-settings.cfg"

var _instances: Array[Node] = []


## A store on the throwaway file. Free it with [method release].
func open() -> Node:
	var settings := Settings.new()
	settings.open(TEST_PATH)
	_instances.append(settings)
	return settings


func release() -> void:
	for instance in _instances:
		instance.free()
	_instances.clear()


static func clean() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


## The tail of a check's message: what went wrong, or nothing when nothing did.
static func detail(problems: Array[String]) -> String:
	return "" if problems.is_empty() else ": " + ", ".join(problems)
