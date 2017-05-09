#!/bin/bash

# assume 5.6 server using login_path

. ~/.bash_profile

mysql --login-path=root  <<!
SELECT table_schema "Name", 
sum( data_length + index_length ) / 1024 / 
1024 "Size(MB)", 
sum( data_free )/ 1024 / 1024 "Free(MB)" 
FROM information_schema.TABLES 
GROUP BY table_schema ; 
!

