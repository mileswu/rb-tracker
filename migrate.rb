require 'mysql'
require 'config'

db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)

# Reset tables
db.query "DROP TABLE `transfer_history`"

db.query "CREATE TABLE IF NOT EXISTS `transfer_history` (
  `uid` int(11) NOT NULL default '0',
  `fid` int(11) NOT NULL default '0',
  `uploaded` bigint(20) NOT NULL default '0',
  `downloaded` bigint(20) NOT NULL default '0',
  `remaining` int(11) NOT NULL default '0',
  `active` enum('0','1') NOT NULL default '0',
  `connectable` enum('0','1') NOT NULL default '0',
  `starttime` int(11) NOT NULL default '0',
  `last_announce` int(11) NOT NULL default '0',
  `snatched` int(11) NOT NULL default '0',
  `snatched_time` int(11) default '0',
  `seeding` enum('0','1') NOT NULL default '0',
  `seedtime` int(30) NOT NULL default '0',
  `hnr` enum('0','1','2') NOT NULL default '0',
  `hnrsettime` datetime NOT NULL default '0000-00-00 00:00:00',
  PRIMARY KEY  (`uid`,`fid`),
  KEY `uid` (`uid`),
  KEY `fid` (`fid`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;"

db.query "CREATE TABLE IF NOT EXISTS transfer_ips (
  last_announce int(11) NOT NULL default '0',
  starttime int(11) NOT NULL default '0',
  uid int(11) NOT NULL default '0',
  fid int(11) NOT NULL default '0',
  peer_id BINARY(20) default '',
  ip CHAR(15) default '',
  port int(11) NOT NULL default '0',
  PRIMARY KEY (uid, fid, peer_id),
  KEY (uid, fid)
 ) ENGINE=InnoDB;
 " 

# Migrate xbt_files_users_dead
query_values = []
query_b = "INSERT INTO transfer_history (uid, fid, uploaded, downloaded, connectable, seeding, last_announce, seedtime, active, remaining) VALUES\n"
query_e = "\nON DUPLICATE KEY UPDATE uploaded = uploaded + VALUES(uploaded), downloaded = downloaded + VALUES(downloaded), connectable = VALUES(connectable), seeding = VALUES(seeding), seedtime = seedtime + VALUES(seedtime), last_announce = VALUES(last_announce), active = VALUES(active), remaining = VALUES(remaining)"

results = db.query "SELECT * from xbt_files_users_dead"
counter = 0
results.each_hash do |i| #WE LOST ALL THE TIME SPENT DATA for dead
	query_values << "('#{i['uid']}', '#{i['fid']}', '#{i['uploaded']}', '#{i['downloaded']}', '1', '#{i['remaining'] == '0' ? 1 : 0}', '#{i['mtime']}', '#{i['timespent']}', '0', '#{i[:remaining]}')"
	counter += 1
	if(counter%1000 == 0)
		db.query(query_b + query_values.join(",\n") + query_e)
		query_values = []
	end
end

results = db.query "SELECT * from xbt_files_users"
counter += results.num_rows
results.each_hash do |i|
	query_values << "('#{i['uid']}', '#{i['fid']}', '#{i['uploaded']}', '#{i['downloaded']}', '1', '#{i['remaining'] == '0' ? 1 : 0}', '#{i['mtime']}', '#{i['timespent']}', '0', '#{i[:remaining]}')"
	counter += 1
	if(counter%1000 == 0)
		db.query(query_b + query_values.join(",\n") + query_e)
		query_values = []
	end
end

if(counter%1000 != 0)
	db.query(query_b + query_values.join(",\n") + query_e)
end

# Migrate xbt_snatched
query_b = "INSERT INTO transfer_history (uid, fid, snatched, snatched_time) VALUES\n"
query_e = "\nON DUPLICATE KEY UPDATE snatched = snatched + VALUES(snatched), snatched_time = VALUES(snatched_time)"
query_values = []
results = db.query "SELECT * from xbt_snatched"
counter = 0

results.each_hash do |i|
	query_values << "('#{i['uid']}', '#{i['fid']}', '1', '#{i['tstamp']}')"
	counter += 1
	if(counter%1000 == 0)
		db.query(query_b + query_values.join(",\n") + query_e)
		query_values = []
	end
end
if(counter%1000 != 0)
	db.query(query_b + query_values.join(",\n") + query_e)
	query_values = []
end

# Raname old tables
#db.query "RENAME TABLE xbt_files_users TO xbt_files_users_old




