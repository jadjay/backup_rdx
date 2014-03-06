#!/bin/bash

################################################################
# Script	 	RDXbackup.sh
#
# Description	Suite au branchement d'un disque de backup
#		Udev repère le numéro de série du support ou des
#		disques.
#		On les fait correspondre avec la variable PERIPH
#		ci-dessous. Ensuite ce script vérifie l'UUID de
#		la partition sur laquelle sera effectué le backup.
#
# 		La partition sera cryptée, le script la déchiffre
#		et la monte à l'endroit de la variable BACKDIR. 
#
#		Ce script fait une sauvegarde d'un Volume Logique 
#		complet via un snapshot.
#
#		* Création du snapshot
#		* Montage du snapshot
#		* Copie via Rsync
#		* Suppression du snapshot
#
#		* sauvegarde local de /etc et des paquets installés
#		
#		* Démontage du périphérique
#		* Ejection du périphérique
#
#	note : Chaque résultat de commande est vérifié, et le programme 
#	s'arrête à la première erreur.
#
#	* Règle crontab a ajouter :
#	/etc/crontab:00 10	* * 1-5	root	/root/sbin/backup-RDX.sh >> /root/journal_backup/journal_`date +\%F`.log 2>&1
#################################################################
usage() {
	echo "$0 [backup_rdx.conf]"
	echo "Le fichier de conf est obligatoire le fichier backup_rdx.conf local au dossier est utilisé par défaut"
}

CONF=$1
CONF=${CONF:="./backup_rdx.conf"}

if [ ! -f $CONF ]
	then
		usage
		exit 1
fi

. $CONF

ROOT_UID=0     # Only users with $UID 0 have root privileges.
E_NOTROOT=87   # Non-root exit error.
#E_XCD=86       # Can't change directory?
E_BAD_ARGS=65	# Mauvais arguments passés en appel du programme
E_PARAM_ERR=85  # Param error.


#################################################
#
# Ecrit au fur et à mesure dans les logs du jour
#
#################################################
# Permet la vérification / le débugage du déroulement du script.
function journal {
        echo -e "$(date) -- $1" >> $LOGS/$LOGFILE
}

#################################################
#
# Si quelque chose ne se passe pas commme prévu,
# on quitte en envoyant un mail contenant le log
# du programme
#
#################################################
function terminate {
	cat $LOGS/$LOGFILE | /usr/bin/mail -s "Probleme Backup RDX - $QUI" $POSTMASTER
	exit 1
}

###########################################
#
# Vérification de l'UUID du disque
#
### UUID AUTORISES (valeurs à compléter)
# DISQUE 1
#ed5a51e9-bfef-4134-a530-4bae9433a21bc
# ...
#
###########################################
function checkuuid {

	for (( i=0 ; i < ${#UUIDS[@]} ; i++ ))
		do
		if [ "${UUIDS[$i]}" = "$1" ]
			then
			journal "\nDisque Identifié : numéro $(($i+1))"
			
			return 0
		fi
	done
	# Si pas identifié
	return 1
}

##########################################
#
# Fonction appelée en cas d'erreur dans le
# processus d'arrêt / redémarrage des VMs
#
###########################################
function verifStarted {

	echo "VM dont l'exécution doit être vérifiée : $1" >>$LOGS/$LOGFILE
	local vm=$1

	case $2 in
		loc)
			# on vérifie que la machine est allumée
        		virsh domstate "$vm" | grep "running"

			local ok=0
        		local count=0
        		while [[ $ok -eq 0 && $count -lt 3 ]]
        		do
        		        # on attends 40 secondes
        		        sleep 40
        		        ((count++))
        		        # on vérifie que la machine est allumée
        		        virsh domstate "$vm" | grep "running" 
        		        if [ $? -ne 0 ]
        		                then
        		                journal "\nProblème vérification que la vm $vm tourne. Essai numéro $count"
					virsh start $vm
        		        else
        		                # on sort
        		                local ok=1;
        		                journal "\nVM $vm tourne. OK"
        		        fi
			# Fin des essais
        		if [[ $ok -eq 0 && $count -gt 2 ]]
        		        then
        		        journal "\nVM $vm refuse de se lancer. Sortie du programme en mode DEGRADE ."
        		fi

        		done
		   ;;
		dist)
			# Sauvegarde à distance
			local SSHUSER="$3"
			local SSHHOST="$4"
			# on vérifie que la machine est allumée
        		ssh $SSHUSER@$SSHHOST sudo virsh domstate "$vm" | grep "running"

			local ok=0
        		local count=0
        		while [[ $ok -eq 0 && $count -lt 3 ]]
        		do
        		        # on attends 40 secondes
        		        sleep 40
        		        ((count++))
        		        # on vérifie que la machine est allumée
        		        ssh $SSHUSER@$SSHHOST sudo virsh domstate "$vm" | grep "running" 
        		        if [ $? -ne 0 ]
        		                then
        		                journal "\nProblème vérification que la vm $vm tourne. Essai numéro $count";
					ssh $SSHUSER@$SSHHOST sudo virsh start $vm
        		        else
        		                # on sort
        		                local ok=1;
        		                journal "\nVM $vm tourne. OK"
        		        fi
			# Fin des essais
        		if [[ $ok -eq 0 && $count -gt 2 ]]
        		        then
        		        journal "\nVM $vm refuse de se lancer. Sortie du programme en mode DEGRADE ."
        		fi

        		done
		   ;;
	esac

}

##########################################
#
# Fonction principale de backup des VMs
#
# 	A DISTANCE avec SSH et rsync
#   note : l'utilisateur avec lequel on 
#   s'identifie doit avoir les droits sudo
#   sur les programmes appelés.
#
###########################################
function distBackup {

	local vm=$1

	# Sauvegarde à distance
	local SSHUSER="$2"
	local SSHHOST="$3"

	journal "\n\n------------------------------\nArret de la machine virtuelle $vm"
	
	local IMG=`ssh $SSHUSER@$SSHHOST sudo virsh dumpxml $vm | grep "source file" | cut -d"'" -f2`

	# retour grep à 0 et IMG non vide
	if [[ $? -eq 0 && "$j" ]]
		then
		
		journal "\nChemin de l'image : $j"
		
		ok=0
                count=0
                while [[ $ok -eq 0 && $count -lt 3 ]]
                do
                        ssh $SSHUSER@$SSHHOST sudo virsh shutdown "$vm" 2>>$LOGS/$LOGFILE
                        # on attends 40 secondes
                        sleep 40
                        ((count++))
                        # on vérifie que la machine est éteinte
                        ssh $SSHUSER@$SSHHOST sudo virsh domstate "$vm" | grep "shut off" 
                        if [ $? -ne 0 ]
                                then
                                journal "\nProblème vérification arrêt de la vm $vm. Essai numéro $count"
                        else
                                # on sort
                                ok=1;
                                journal "\nVM $vm éteinte."
                        fi

        	        if [[ $ok -eq 0 && $count -gt 2 ]]
        	                then
        	                journal "\nVM $vm ne veut pas s'éteindre. Sortie du programme."
				verifStarted $vm dist
        	                terminate
        	        fi

                done

		# Infos supplémentaires sur le timing pour les logs
		echo "Démarrage de la sauvegarde de la VM $vm à `date +%c`" >> $LOGS/$LOGFILE

		# Si la VM est composée de plusieurs fichiers image
		for j in $IMG
		do
			# sauvegarde de l'image | 31/01/2012 ajout inplace	
			# --inplace 		=> pas de fichier buffer
			# --no-whole-file	=> lit le fichier par blocs
			# --sparse 		=> sauvegarde la taille "efficace" du fichier image
			rsync -av --inplace -e "ssh" --rsync-path="sudo /usr/bin/rsync" $SSHUSER@$SSHHOST:"$j" $BACKDIR >> $LOGS/$LOGFILE 2>&1
			if [[ $? -ne 0 ]]
				then
					LOGBACKUP+=\n"Problème sauvegarde du fichier vm $j. Redémarrage de la machine virtuelle $vm. SAVEGARDE ECHOUEE !!"
					verifStarted $vm dist "$SSHUSER" "$SSHHOST"
					terminate
			fi
		done
			
		# on attend 5 secondes
		sleep 5
		# Infos supplémentaires sur le timing pour les logs
	        journal "\nFin de la sauvegarde de la VM $vm"
	
		# Redémarrage de la VM
		ssh $SSHUSER@$SSHHOST sudo virsh start $vm 2>>$LOGS/$LOGFILE || { journal "\nProblème redémarrage vm $vm. Arrêt du programme !";verifStarted $vm dist "$SSHUSER" "$SSHHOST";terminate;}
		
		# on attend 40 secondes
		sleep 40

		# on vérifie que la machine est bien rallumée
		ssh $SSHUSER@$SSHHOST LANG=C sudo virsh list --all | grep "running" | grep "$vm" || { journal "\nProblème Redémarrage vm $vm ! Sortie du programme.";verifStarted $vm dist "$SSHUSER" "$SSHHOST";terminate;}
	
		journal "\nVM $vm sauvegardée et redémarée."
	
	else
		$LOGBACKUP.="Impossible de trouver le fichier image correspondant, sortie du programme !"
		terminate
	fi 
	
}

##########################################
#
# Fonction principale de backup des VMs
# avec arrêt des machines
#
###########################################
function backup {

	# On pourrait aussi utiliser virsh save guest_name guest_state_file
	# virsh save
	
	local vm=$1
	journal "\n\n------------------------------\nArret de la machine virtuelle $vm"
	
	#IMG=`find $BACKDIR -iname $vm`
	local IMG=`virsh dumpxml $vm | grep "source file" | cut -d"'" -f2`
	
	# retour find à 0 et IMG non vide
	if [[ $? -eq 0 && $IMG ]]
		then
		
		journal "\nChemin de l'image : $IMG"
		
		ok=0
                count=0
                while [[ $ok -eq 0 && $count -lt 3 ]]
                do
                        virsh shutdown "$vm" 2>>$LOGS/$LOGFILE
                        # on attends 40 secondes
                        sleep 40
                        ((count++))
                        # on vérifie que la machine est éteinte
                        virsh domstate "$vm" | grep "shut off" 
                        if [ $? -ne 0 ]
                                then
                                journal "\nProblème vérification arrêt de la vm $vm. Essai numéro $count";
                        else
                                # on sort
                                ok=1;
                                journal "\nVM $vm éteinte."
                        fi
                if [[ $ok -eq 0 && $count -gt 2 ]]
                        then
                        journal "\nVM $vm ne veut pas s'éteindre. Sortie du programme."
			verifStarted $vm loc
                        terminate
                fi

                done

		# Infos supplémentaires sur le timing pour les logs
		echo "Démarrage de la sauvegarde de la VM $vm à `date +%c`" >> $LOGS/$LOGFILE

		# Si la VM est composée de plusieurs fichiers image
		for j in $IMG
		do
			# sauvegarde de l'image | 31/01/2012 ajout inplace	
			# --inplace 		=> pas de fichier buffer
			# --no-whole-file	=> lit le fichier par blocs
			# --sparse 		=> sauvegarde la taille "efficace" du fichier image
			# note : sparse est inutile si l'image est au format qcow2
			rsync -av --inplace $j $BACKDIR >> $LOGS/$LOGFILE 2>&1
			if [[ $? -ne 0 ]]
			then
				LOGBACKUP+=\n"Problème sauvegarde du fichier vm $j. Redémarrage de la machine virtuelle $vm. SAVEGARDE ECHOUEE !!"
				verifStarted $vm loc
        	               	terminate
			fi
		done
	
		# on attend 5 secondes
		sleep 5
		# Infos supplémentaires sur le timing pour les logs
	        echo "Fin de la sauvegarde de la VM $vm à `date +%c`" >> $LOGS/$LOGFILE

		# Redémarrage de la VM
		virsh start $vm 2>>$LOGS/$LOGFILE || { journal "\nProblème redémarrage vm $vm. Arrêt du programme !";verifStarted $vm loc;terminate;}
		
		# on attend 40 secondes
		sleep 40

		# on vérifie que la machine est bien rallumée
		LANG=C virsh list --all | grep "running" | grep "$vm" || { journal "\nProblème Redémarrage vm $vm ! Sortie du programme.";verifStarted $vm loc;terminate;}
	
		journal "\nVM $vm sauvegardée et redémarée."
	
	else
		$LOGBACKUP.="Impossible de trouver le fichier image correspondant, sortie du programme !"
		terminate
	fi 

}

#####################################################
#
# Sauvegarde via snapshot sur Volume Logique
# N'arrête pas les VMs.
#
# Paramètres : 	nom du LV à sauvegarder
#		nom du Groupe de Volume auquel il
#		appartient
#		type de système de fichier à utiliser
#		
#
####################################################
function snapshot {

	local LV="$1"
	local VG="$2"
	local TYPE="$3"
	
        local CONTINUE="1"

	for item in ${listvm[@]}
	do
		virsh suspend $item
	done

	sleep 2
        # Si on rencontre un  problème lors de la création du snapshot, on ne stoppe pas le 
        # programme immédiatement sinon les VMs resteraient en mode suspendu.
	lvcreate -s -n snapsrv -L 10G /dev/$VG/$LV >> $LOG/$LOGFILE 2>&1 && journal "snapshot OK" || { journal "PROBLEME création snapshot";CONTINUE=0;}
	sleep 2

	for item in ${listvm[@]}
	do
		virsh resume $item
	done
        
        # Si le snaphost s'est mal passé, on arrête le programme
        if [[ $CONTINUE -eq 0 ]]
            then
            journal "\n\n !!! Sauvegarde annulée. Veillez à supprimer le snapshot précédent, démonter /dev/RDXbackup\n";terminate;
        fi

	mount -t $TYPE /dev/$VG/snapsrv $MOUNTPOINT 2>>$LOGS/$LOGFILE && journal "montage snap OK" || { journal "\nsnapshot PROBLEME montage $MOUNTPOINT";terminate;}
	
	#rsync -a --inplace $MOUNTPOINT/ $BACKDIR && journal "rsync terminé à `date +%H:%M:%S`"
	# --inplace met à jour les fichiers de destination directement. Plus long que de la copie directe qui ne s'embete pas à contrôler ce qu'il y a à modifier dans les fichiers images.  Sur 247G on gagne un peu plus de deux heures en enlevant l'option --inplace.
        # utilisation de cp pour supprimer AVANT, sinon pb, une image à 147Go bloque rsync (problème d'espace disque)
	cp -r -v $MOUNTPOINT/* $BACKDIR >> $LOGS/$LOGFILE 2>&1 && journal "copie terminée" || { journal "PROBLEME copie des Vms $MOUNTPOINT";terminate;}

	umount $MOUNTPOINT 2>>$LOGS/$LOGFILE && journal "démontage snap $MOUNTPOINT OK" || journal "PROBLEME démontage snap"
	
        sleep 2

	lvremove -f $VG/snapsrv 2>>$LOGS/$LOGFILE && journal "destruction snap OK" || journal "PROBLEME suppresion volume snapsrv"
}



function init {

    local ok=0
    local count=0


    # Vérification de l'UUID du disque
    diskid=`/sbin/blkid -o value -s UUID $PERIPH`
    checkuuid "$diskid" || { journal "\nDisque non identifié ! Sortie du programme.";terminate;}
    
    # On mount le disque de sauvegarde 
    mount -t $FSTYPE $PERIPH $BACKDIR 2>>$LOGS/$LOGFILE || { journal "\nImpossible de monter le disque Sortie du programme.";terminate;}
    
    # Vérification de la présence du périphérique
    mount|grep $BACKDIR || { journal "\nPériphérique $PERIPH non monté sur $BACKDIR ! Sortie du programme !";terminate;}

}




######################################################
#
# 	MAIN 
#
######################################################

# Doit être root
# Run as root if you don't want to get permission limits
if [ "$UID" -ne "$ROOT_UID" ]
    then
        echo "Vous n'êtes pas en mode root. Sortie du programme."
         exit $E_NOTROOT
fi

# Création des répertoire définis plus haut s'ils n'existent pas
[ -d $LOGS ] || { journal "\nCréation du répertoire de logs dans $LOGS";mkdir -p $LOGS;}

[ -d $BACKDIR ] || { journal "\nCréation du répertoire où monter le disque de sauvegarde dans $BACKDIR";mkdir -p $BACKDIR;}

[ -d $MOUNTPOINT ] || { journal "\nCréation du répertoire où monter le snapshot dans $MOUNTPOINT";mkdir -p $MOUNTPOINT;}

journal "*** Programme Sauvegarde RDX Backup ***\n\n`date +%c`"

# retourne la liste des machines virtuelles lancées dans un tableau
# Utilisée par la suite dans les fonctions de backup

if [ ${#listvm[@]} -eq 0 ]
	then
		listvm=(`LANG=C virsh list | grep running | sed 's/\(\s\)\(\s\)*/\1/g' |  cut -d" " -f3`)
fi

# affichage du tableau à titre informatif
journal "\nListe des machines virtuelles allumées  = ${listvm[*]}"

# Identification, déchiffrage et montage du disque de sauvegarde
init

journal "Derniers changements effectués sur les fichiers : \n"
ls -lcha $BACKDIR >> $LOGS/$LOGFILE
journal "Taille totale sur la cassette : \n"
du -ch --max-depth=1 $BACKDIR >> $LOGS/$LOGFILE

if [ ${#listvm[@]} -ne 0 ] 
	then
	journal "\nVM allumée(s) :  ${#listvm[*]}"	

	# Arrêt d'une machine, puis backup, puis redémarrage
	for item in ${listvm[@]}
	do
		backup $item 2>>$LOGS/$LOGFILE
	done
else
	journal "\n\nAucune VMs en fonctionnement ! Est-ce voulu ? Le programme continu, peut-être que des sauvegardes à distance sont programmées...\n"
fi

# Sauvegarde de /etc et liste des paquets installés sur l'hôte
journal "Archivage du dossier /etc de l'hôte..."
tar czf $BACKDIR/backupHote.etc.tgz /etc >> $LOGS/$LOGFILE 2>&1 || { journal "ECHEC !";}
journal "Sauvegarde de la liste des paquets intallés sur l'hôte..."
dpkg --get-selections > $BACKDIR/dpkg.bak || { journal -n "ECHEC !";}
	
# Exemple de sauvegarde de la VM RDXmail à distance
###	distBackup RDXmail "RDXbackup" "host.entreprise.local"

# Sauvegarde par snapshot (LV VG type_système_fichier)
###	snapshot LV VG type_système_fichier


# Fermetures...
journal "Fin de la sauvegarde."
journal "Derniers changements effectués sur les fichiers : \n"
ls -lcha $BACKDIR >> $LOGS/$LOGFILE
journal "Taille totale sur la cassette : \n"
du -ch --max-depth=1 $BACKDIR >> $LOGS/$LOGFILE

# Démontage et éjection du périphérique
umount $BACKDIR 2>>$LOGS/$LOGFILE || { journal "problème démontage $BACKDIR";terminate;}

# Ejection de la cassette
eject $PERIPH 2>>$LOGS/$LOGFILE || { journal "problème éjection $PERIPH";terminate;}

echo -e "`date +%c` => Tout s'est bien passé. \n\n$LOGBACKUP"  >> $LOGS/$LOGFILE
cat $LOGS/$LOGFILE | /usr/bin/mutt -s "OK Backup $QUI" $POSTMASTER

exit 0
