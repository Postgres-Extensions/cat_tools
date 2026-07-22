EXTENSIONS += cat_tools
EXTENSION_SQL_FILES += sql/cat_tools.sql
EXTENSION_cat_tools_VERSION := 0.3.0
EXTENSION_cat_tools_VERSION_FILE	= sql/cat_tools--$(EXTENSION_cat_tools_VERSION).sql
EXTENSION_VERSION_FILES		+= $(EXTENSION_cat_tools_VERSION_FILE)
$(EXTENSION_cat_tools_VERSION_FILE): sql/cat_tools.sql cat_tools.control
	@echo '/* DO NOT EDIT - AUTO-GENERATED FILE */' > $(EXTENSION_cat_tools_VERSION_FILE)
	@cat sql/cat_tools.sql >> $(EXTENSION_cat_tools_VERSION_FILE)

