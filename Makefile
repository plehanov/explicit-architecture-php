# Makefile
#
# This file contains the commands most used in DEV, plus the ones used in CI and PRD environments.
#
# The commands are to be organized semantically and alphabetically, so that similar commands are nex to each other
# and we can compare them and update them easily.
#
# For example in a format like `subject-action-environment`, ie:
#
#   box-build-base:     # box is a generic term, we don't care if it is a virtual machine or a container
#   box-build-ci:
#   box-build-dev:
#   box-push-base:
#   box-push-prd:
#   cs-fix:             # here we don't use the env because we only do it in dev
#   dep-install:        # again, by default the env is dev
#   dep-install-ci:
#   dep-install-prd:
#   dep-update:
#   test:               # here we don't even have a subject because it is the app itself, and by default the env is dev
#   test-ci:            # here we don't even have a subject because it is the app itself
#

# Mute all `make` specific output. Comment this out to get some debug information.
.SILENT:

# .DEFAULT: If the command does not exist in this makefile
# default:  If no command was specified
.DEFAULT default:
	if [ -f ./Makefile.custom ]; then \
	    $(MAKE) -f Makefile.custom "$@"; \
	else \
	    if [ "$@" != "" ]; then echo "Command '$@' not found."; fi; \
	    $(MAKE) help; \
	    if [ "$@" != "" ]; then exit 2; fi; \
	fi

help:
	@echo "Usage:"
	@echo "     make [command]"
	@echo
	@echo "Available commands:"
	@grep '^[^#[:space:]].*:' Makefile | grep -v '^default' | grep -v '^\.' | grep -v '=' | grep -v '^_' | sed 's/://' | xargs -n 1 echo ' -'

########################################################################################################################

CONTAINER_NAME_BASE="hgraca/explicit-architecture:app.sfn.base"
CONTAINER_NAME_PRD="hgraca/explicit-architecture:app.sfn.prd"
COVERAGE_REPORT_PATH="var/coverage.clover.xml"
DB_PATH='var/data/blog.sqlite'

box-build-base:
	docker build -t ${CONTAINER_NAME_BASE} -f ./build/container/app.base.dockerfile .

box-build-ci:
	docker-compose -f build/container/ci/docker-compose.yml build --force-rm app

box-build-dev:
	docker-compose -f build/container/dev/docker-compose.yml build --force-rm app

box-build-prd:
	make db-setup-guest
	docker-compose -f build/container/prd/docker-compose.yml build --force-rm app

box-push-base:
	docker login
	docker push ${CONTAINER_NAME_BASE}

box-push-prd:
	docker login
	docker push ${CONTAINER_NAME_PRD}

#   We run this in tst ENV so that we never run it with xdebug on
cs-fix:
	ENV='tst' ./bin/run php vendor/bin/php-cs-fixer fix --verbose

db-migrate:
	ENV='dev' ./bin/run make db-migrate-guest

db-migrate-guest:
	php bin/console doctrine:migrations:migrate --no-interaction

db-setup:
	ENV='dev' ./bin/run make db-setup-guest

db-setup-guest:
	mkdir -p ./var/data
	php bin/console doctrine:database:drop -n --force
	php bin/console doctrine:database:create -n
	php bin/console doctrine:schema:create -n
	$(MAKE) db-migrate-guest
	php bin/console doctrine:fixtures:load -n

dep_analyzer-install:
	curl -LS http://get.sensiolabs.de/deptrac.phar -o deptrac
	chmod +x deptrac
	echo
	echo "If you want to create nice dependency graphs, you need to install graphviz:"
	echo "    - For osx/brew: $ brew install graphviz"
	echo "    - For ubuntu: $ sudo apt-get install -y graphviz"
	echo "    - For windows: https://graphviz.gitlab.io/_pages/Download/Download_windows.html"

dep-clearcache-guest:
	composer clearcache

dep-install:
	ENV='dev' ./bin/run composer install

#   We use this only when building the box used in the CI
dep-install-ci-guest:
	composer install --optimize-autoloader --no-ansi --no-interaction --no-progress --no-scripts

#   We use this only when building the box used in PRD
dep-install-prd-guest:
	composer install --no-dev --optimize-autoloader --no-ansi --no-interaction --no-progress --no-scripts

dep-update:
	ENV='dev' ./bin/run composer update

deploy_stg-ci:
	bin/deploy staging ${SCRUTINIZER_BRANCH}

deploy_prd-ci:
	bin/deploy production ${SCRUTINIZER_BRANCH}

shell:
	docker exec -it app.sfn.dev sh

test:
	- ENV='tst' ./bin/stop # Just in case some container is left over stopped, as is the case after PHPStorm runs tests
	ENV='tst' ./bin/run
	- $(MAKE) cs-fix
	ENV='tst' ./bin/run php vendor/bin/phpunit
	ENV='tst' ./bin/stop
	$(MAKE) test-acc
	$(MAKE) test-dep

test-acc:
	- ENV='tst' ./bin/stop # Just in case some container is left over stopped, as is the case after PHPStorm runs tests
	ENV='tst' ./bin/run make db-setup-guest
	ENV='tst' docker-compose -f build/container/tst/docker-compose.yml up -d -t 0
	php vendor/bin/codecept run -g acceptance
	ENV='tst' ./bin/stop

test-acc-ci:
	- ENV='prd' ./bin/stop # Just in case some container is left over stopped, as is the case after PHPStorm runs tests
	ENV='prd' docker-compose -f build/container/prd/docker-compose.yml up -d -t 0
	php vendor/bin/codecept run -g acceptance
	ENV='prd' ./bin/stop

test-ci:
	$(MAKE) box-build-prd
	$(MAKE) box-build-ci  # This is always run by default in the Ci, but having it here makes it possible to run in dev
	ENV='ci' ./bin/run
	ENV='ci' ./bin/run php vendor/bin/php-cs-fixer fix --verbose --dry-run
	ENV='ci' ./bin/run make test_cov-guest
	docker exec -it app.sfn.ci cat ${COVERAGE_REPORT_PATH} > ${COVERAGE_REPORT_PATH}
	$(MAKE) test-acc-ci
	$(MAKE) test-dep-ci

test-dep:
	$(MAKE) test-dep-components
	$(MAKE) test-dep-layers
	$(MAKE) test-dep-class

test-dep-graph:
	$(MAKE) test-dep-components-graph
	$(MAKE) test-dep-layers-graph
	$(MAKE) test-dep-class-graph

test-dep-ci:
	$(MAKE) dep_analyzer-install
	$(MAKE) test-dep

test-dep-components:
	./deptrac analyze depfile.components.yml --formatter-graphviz=0

test-dep-components-graph:
	./deptrac analyze depfile.components.yml --formatter-graphviz-dump-image=var/deptrac_components.png --formatter-graphviz-dump-dot=var/deptrac_components.dot

test-dep-layers:
	./deptrac analyze depfile.layers.yml --formatter-graphviz=0

test-dep-layers-graph:
	./deptrac analyze depfile.layers.yml --formatter-graphviz-dump-image=var/deptrac_layers.png --formatter-graphviz-dump-dot=var/deptrac_layers.dot

test-dep-class:
	./deptrac analyze depfile.classes.yml --formatter-graphviz=0

test-dep-class-graph:
	./deptrac analyze depfile.classes.yml --formatter-graphviz-dump-image=var/deptrac_class.png --formatter-graphviz-dump-dot=var/deptrac_class.dot

test_cov:
	ENV='tst' ./bin/run make test_cov-guest

# We use phpdbg because is part of the core and so that we don't need to install xdebug just to get the coverage.
# Furthermore, phpdbg gives us more info in certain conditions, ie if the memory_limit has been reached.
test_cov-guest:
	phpdbg -qrr vendor/bin/phpunit --coverage-text --coverage-clover=${COVERAGE_REPORT_PATH}

test_cov-publish:
	bash -c 'bash <(curl -s https://codecov.io/bash)'

up:
	if [ ! -f ${DB_PATH} ]; then $(MAKE) db-setup; fi
	$(eval UP=ENV=dev docker-compose -f build/container/dev/docker-compose.yml up -t 0)
	$(eval DOWN=ENV=dev docker-compose -f build/container/dev/docker-compose.yml down -t 0)
	- bash -c "trap '${DOWN}' EXIT; ${UP}"

up-prd:
	$(eval UP=ENV=prd docker-compose -f build/container/prd/docker-compose.yml up -t 0)
	$(eval DOWN=ENV=prd docker-compose -f build/container/prd/docker-compose.yml down -t 0)
	- bash -c "trap '${DOWN}' EXIT; ${UP}"
