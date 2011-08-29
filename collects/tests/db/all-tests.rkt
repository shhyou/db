#lang racket/base
(require racket/match
         racket/cmdline
         racket/file
         rackunit
         rackunit/text-ui
         racket/unit
         db
         "config.rkt"
         (prefix-in db-
                    (combine-in "db/connection.rkt"
                                "db/query.rkt"
                                "db/sql-types.rkt"
                                "db/concurrent.rkt"))
         (prefix-in gen-
                    "gen/sql-types.rkt"))
(provide (all-defined-out))

#|

RUNNING THE TESTS
-----------------

First, set up the testing environment as described in the following
subsections.

Then, run the tests with the following command line:

  racket -l tests/db/all-tests -- -g <label> ...

Each <label> is either a <dsn> or a <confname>.

== <dsn> ==

A <dsn> is turned into a symbol and looked up using 'get-dsn'. The
db-specific tests (which is most of them) are run using the resulting
data source. The data source must conform to the following rules:

 - It must include all necessary connection arguments (including the
   password, if one is required).

 - It should have an extension property named 'db:test whose value is
   a list. The list should contain exactly one of the following
   symbols, specifying the SQL dialect used by the data source: 'ispg,
   'ismy, 'issl, 'isora, 'isdb2.

 - If either 'isora or 'isdb2 is set, the database should already be
   populated with the "the_numbers" table (see config.rkt for definition
   and test data). Otherwise, it is automatically created as a temporary
   table for each test case.

Running the tests on a new database system will almost certainly
require changing the test suite to generate the correct SQL dialect
and to selectively disable tests that can't run on a particular
system.

== <confname>: Defining testing configurations ==

The "db-test.rktd" pref file (see definition of 'pref-file' below
gives a mapping from <confnames> (ie, symbols) to <conf>s, which
aggregate multiple testing data sources into a single profile.

<conf> ::= (profile <conf> ...)
         | (dsn <symbol>)
         | (ref <symbol>)

Testing profiles are flattened, not hierarchical.

|#

;; ----------------------------------------

(define pref-file
  (make-parameter (build-path (find-system-path 'pref-dir) "db-test.rktd")))

(define (get-dbconf name)
  (let ([conf (get-preference name (lambda () #f) 'timestamp (pref-file))])
    (if conf
        (parse-dbconf conf)
        (let ([r (get-dsn name)])
          (if r
              (list (dbconf name r))
              (error 'get-dbconf "no such dbconf: ~e" name))))))

(struct dbconf (name dsn) #:transparent)

(define-syntax-rule (expect name pred)
  (unless (pred name) (error 'parse "bad ~a: ~e" 'name name)))

;; parse-dbconf : sexpr -> (listof dbconf?)
(define (parse-dbconf x)
  (match x
    [(list 'profile dbconfs ...)
     (apply append (map parse-dbconf dbconfs))]
    [(list 'ref conf-name)
     (expect conf-name symbol?)
     (get-dbconf conf-name)]
    [(list 'dsn dsn-name)
     (expect dsn-name symbol?)
     (list (dbconf dsn-name (get-dsn dsn-name)))]))

;; ----

(define (dbconf->unit x)
  (match x
    [(dbconf dbtestname (and r (data-source connector _args exts)))
     (let* ([connect (lambda () (dsn-connect r))]
            [dbsys (case connector ((odbc-driver) 'odbc) (else connector))]
            [dbflags (cond [(assq 'db:test exts) => cadr]
                           [else '()])])
       (unit-from-context database^))]))

(define (odbc-unit dbtestname dbflags dbargs)
  (dbconf->unit
   (dbconf dbtestname (data-source 'odbc dbargs `((db:test ,dbflags))))))

;; ----

(define-unit db-test@
  (import database^
          (tag connect (prefix connect: test^))
          (tag query (prefix query: test^))
          (tag sql-types (prefix sql-types: test^))
          (tag concurrent (prefix concurrent: test^)))
  (export test^)
  (define test
    (make-test-suite
     (format "~a tests" dbtestname)
     (list connect:test
           query:test
           sql-types:test
           concurrent:test))))

(define (specialize-test@ db@)
  (compound-unit
   (import)
   (export DB-TEST)
   (link (((DB : database^)) db@)
         (((CONFIG : config^)) config@ DB)
         (((CONNECT-TEST : test^)) db-connection@ CONFIG DB)
         (((QUERY-TEST : test^)) db-query@ CONFIG DB)
         (((SQL-TYPES-TEST : test^)) db-sql-types@ CONFIG DB)
         (((CONCURRENT-TEST : test^)) db-concurrent@ CONFIG DB)
         (((DB-TEST : test^)) db-test@
                               DB
                               (tag connect CONNECT-TEST)
                               (tag query QUERY-TEST)
                               (tag sql-types SQL-TYPES-TEST)
                               (tag concurrent CONCURRENT-TEST)))))

(define (specialize-test db@)
  (define-values/invoke-unit (specialize-test@ db@) (import) (export test^))
  test)

(define (odbc-test dsn [flags null])
  (specialize-test (odbc-unit dsn flags `(#:dsn ,dsn))))

(define generic-tests
  (make-test-suite "Generic tests (no db)"
    (list gen-sql-types:test)))

;; ----

(define (make-all-tests label dbconfs)
  (make-test-suite (format "All ~s tests" label)
    (for/list ([dbconf (in-list dbconfs)])
      (specialize-test (dbconf->unit dbconf)))))

;; ----

(define-syntax-rule (setup-debug db@ c)
  (begin (define-values/invoke-unit db@ (import) (export database^))
         (define-values/invoke-unit config@ (import database^) (export config^))
         (define c (connect-and-setup))))

;; ----------------------------------------

(define gui? #f)
(define include-generic? #f)

;; If no labels given, run generic tests. If labels given, run generic
;; tests only if -g option given.

(command-line
 #:once-each
 [("--gui") "Run tests in RackUnit GUI" (set! gui? #t)]
 [("-g" "--generic") "Run generic tests" (set! include-generic? #t)]
 [("-f" "--config-file") file  "Use configuration file" (pref-file file)]
 #:args labels
 (cond [gui?
        (let* ([dbtests
                (for/list ([label labels])
                  (make-all-tests label (get-dbconf (string->symbol label))))]
               [tests
                (cond [(or include-generic? (null? dbtests))
                       (cons generic-tests dbtests)]
                      [else dbtests])]
               [test/gui (dynamic-require 'rackunit/gui 'test/gui)])
          (apply test/gui tests)
          (eprintf "Press Cntl-C to end.\n") ;; HACK!
          (with-handlers ([exn:break? (lambda _ (newline) (exit))])
            (sync never-evt)))]
       [else
        (when (or include-generic? (null? labels))
          (printf "Running generic tests\n")
          (run-tests generic-tests)
          (newline))
        (for ([label labels])
          (printf "Running ~s tests\n" label)
          (run-tests
           (make-all-tests label (get-dbconf (string->symbol label))))
          (newline))]))