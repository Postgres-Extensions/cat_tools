/*
 * Structural signature dump for every object that belongs to an extension
 * (pg_depend deptype = 'e'), used by bin/structural_diff to compare a
 * database reached via an extension UPDATE against a FRESH install of the
 * same target version. Any nonempty diff between two runs of this query is a
 * bug: the two paths are supposed to produce byte-identical objects.
 *
 * Run via: psql -d DBNAME -v extname="'cat_tools'" -f bin/structural_diff.sql
 *
 * Origin: this generalizes a manual comparison technique (diffing
 * pg_get_functiondef / pg_get_viewdef / type labels / comments / ACLs /
 * extension membership between a fresh install and an updated database) used
 * to find the trigger__parse divergence fixed in
 * https://github.com/Postgres-Extensions/cat_tools/pull/46.
 *
 * Emits one text block per member object, ordered by its pg_describe_object()
 * identity so the SAME object sorts to the SAME position regardless of the
 * OIDs assigned along each installation path. Each block covers:
 *   - a structural definition, using pg_get_functiondef/pg_get_viewdef for
 *     routines/views, an ordered column dump for the one plain table and the
 *     one standalone composite type this extension has, and an ordered label
 *     list for enums -- whichever a member's catalog/kind actually calls for.
 *     Row types implicitly created BY a member relation, and the array type
 *     shadowing any other member type, are skipped: their structure is fully
 *     captured by the relation/base-type entry already, so listing them again
 *     would just duplicate that comparison under a second identity.
 *   - its comment (pg_description), generically via obj_description().
 *   - its ACL, generically via whichever ACL column its catalog has (proacl /
 *     typacl / relacl / nspacl); sorted, since grant order is not meaningful.
 *
 * This is deliberately NOT specific to cat_tools's current object list: any
 * object kind this extension does not (yet) use falls through to the ELSE
 * branch below, which still includes it (via its pg_describe_object identity,
 * comment and ACL) so a future new member is compared at least at that level
 * rather than silently skipped, even though this file does not (yet) know how
 * to render a structural definition for it.
 */
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset fieldsep ''

WITH ext AS (
  SELECT oid FROM pg_extension WHERE extname = :extname
), members AS (
  SELECT d.classid, d.objid
    FROM pg_depend d, ext
   WHERE d.refclassid = 'pg_extension'::regclass
     AND d.refobjid = ext.oid
     AND d.deptype = 'e'
), skip_shadow AS (
  /* Implicit row type of a member relation: same structure as the relation
   * itself, so comparing it too would just duplicate that check. */
  SELECT t.oid
    FROM pg_type t
    JOIN members rel ON rel.classid = 'pg_class'::regclass AND rel.objid = t.typrelid
   WHERE t.typtype = 'c'
  UNION
  /* Array type shadowing another member type: same element type, no
   * independent structure of its own. */
  SELECT t.oid
    FROM pg_type t
    JOIN members base ON base.classid = 'pg_type'::regclass AND base.objid = t.typelem
   WHERE t.typelem <> 0
), acl AS (
  SELECT m.classid, m.objid,
    (
      SELECT array_to_string(array_agg(a::text ORDER BY a::text), ',')
        FROM unnest(
          CASE m.classid
            WHEN 'pg_proc'::regclass      THEN (SELECT proacl FROM pg_proc      WHERE oid = m.objid)
            WHEN 'pg_type'::regclass      THEN (SELECT typacl FROM pg_type      WHERE oid = m.objid)
            WHEN 'pg_class'::regclass     THEN (SELECT relacl FROM pg_class     WHERE oid = m.objid)
            WHEN 'pg_namespace'::regclass THEN (SELECT nspacl FROM pg_namespace WHERE oid = m.objid)
            ELSE NULL
          END
        ) a
    ) AS acl_text
    FROM members m
), relation_cols AS (
  /* Ordered column dump, shared by the plain-table case (pg_class relkind
   * 'r') and the standalone-composite-type case (pg_type typtype 'c' whose
   * typrelid is NOT a member relation, i.e. survived skip_shadow) -- both
   * describe a set of (name, type, not-null, default) columns identically. */
  SELECT m.classid, m.objid,
    (
      SELECT string_agg(
               format(
                 '%s %s%s%s'
                 , a.attname
                 , format_type(a.atttypid, a.atttypmod)
                 , CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
                 , COALESCE(' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid), '')
               )
               , E'\n' ORDER BY a.attnum
             )
        FROM pg_attribute a
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
       WHERE a.attrelid = CASE m.classid
                            WHEN 'pg_class'::regclass THEN m.objid
                            WHEN 'pg_type'::regclass  THEN (SELECT typrelid FROM pg_type WHERE oid = m.objid)
                          END
         AND a.attnum > 0
         AND NOT a.attisdropped
    )
    /* Table constraints (PK/UNIQUE/CHECK/FK) have no equivalent on a
     * standalone composite type, so this is NULL there and simply appends
     * nothing. */
    || COALESCE(
         E'\n' || (
           SELECT string_agg(pg_get_constraintdef(c.oid), E'\n' ORDER BY c.conname)
             FROM pg_constraint c
            WHERE m.classid = 'pg_class'::regclass AND c.conrelid = m.objid
         )
         , ''
       ) AS cols
    FROM members m
   WHERE (m.classid = 'pg_class'::regclass AND (SELECT relkind FROM pg_class WHERE oid = m.objid) = 'r')
      OR (m.classid = 'pg_type'::regclass AND (SELECT typtype FROM pg_type WHERE oid = m.objid) = 'c')
)
SELECT
  '=== ' || pg_describe_object(m.classid, m.objid, 0) || E' ===\n'
  || 'DEFINITION:' || E'\n' || COALESCE(
       CASE
         WHEN m.classid = 'pg_proc'::regclass
           THEN pg_get_functiondef(m.objid)
         WHEN m.classid = 'pg_class'::regclass AND (SELECT relkind FROM pg_class WHERE oid = m.objid) IN ('v', 'm')
           THEN pg_get_viewdef(m.objid, true)
         WHEN m.classid = 'pg_class'::regclass AND (SELECT relkind FROM pg_class WHERE oid = m.objid) = 'r'
           THEN (SELECT cols FROM relation_cols rc WHERE rc.classid = m.classid AND rc.objid = m.objid)
         WHEN m.classid = 'pg_type'::regclass AND (SELECT typtype FROM pg_type WHERE oid = m.objid) = 'e'
           THEN (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = m.objid)
         WHEN m.classid = 'pg_type'::regclass AND (SELECT typtype FROM pg_type WHERE oid = m.objid) = 'c'
           THEN (SELECT cols FROM relation_cols rc WHERE rc.classid = m.classid AND rc.objid = m.objid)
         WHEN m.classid = 'pg_type'::regclass AND (SELECT typtype FROM pg_type WHERE oid = m.objid) = 'd'
           THEN (
             SELECT format(
                      'base=%s notnull=%s default=%s check=%s'
                      , t.typbasetype::regtype, t.typnotnull, t.typdefault
                      , (SELECT string_agg(pg_get_constraintdef(c.oid), ' AND ' ORDER BY c.oid)
                           FROM pg_constraint c WHERE c.contypid = m.objid)
                    )
               FROM pg_type t WHERE t.oid = m.objid
           )
         WHEN m.classid = 'pg_cast'::regclass
           THEN (
             SELECT format(
                      'CAST (%s AS %s) METHOD %s CONTEXT %s'
                      , ct.castsource::regtype, ct.casttarget::regtype
                      , CASE ct.castmethod
                          WHEN 'f' THEN 'FUNCTION ' || ct.castfunc::regprocedure::text
                          WHEN 'i' THEN 'INOUT'
                          WHEN 'b' THEN 'BINARY COERCION'
                        END
                      , ct.castcontext
                    )
               FROM pg_cast ct WHERE ct.oid = m.objid
           )
         ELSE NULL
       END
       , '(no structural definition rendered for this object kind -- see identity/comment/ACL below)'
     )
  || E'\n' || 'COMMENT: ' || COALESCE(obj_description(m.objid, m.classid::regclass::text), '(none)')
  || E'\n' || 'ACL: '     || COALESCE((SELECT acl_text FROM acl WHERE acl.classid = m.classid AND acl.objid = m.objid), '(none)')
  || E'\n'
  AS block
  FROM members m
  LEFT JOIN skip_shadow s ON m.classid = 'pg_type'::regclass AND s.oid = m.objid
 WHERE s.oid IS NULL
 ORDER BY pg_describe_object(m.classid, m.objid, 0);
